import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/money/money.dart';
import '../../../domain/services/business_report_service.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/money_text.dart';
import '../../../shared/widgets/section_header.dart';

/// A month, set out the way a shop owner reads one.
///
/// Four questions, in the order she asks them: what did I make, where did
/// the money come in, what went out, and when am I busy.
class BusinessReportScreen extends ConsumerStatefulWidget {
  const BusinessReportScreen({super.key});

  @override
  ConsumerState<BusinessReportScreen> createState() =>
      _BusinessReportScreenState();
}

class _BusinessReportScreenState extends ConsumerState<BusinessReportScreen> {
  late String _month = DateFormat(
    'yyyy-MM',
  ).format(ref.read(clockProvider).now());

  @override
  Widget build(BuildContext context) {
    final AsyncValue<BusinessReport> report = ref.watch(
      monthReportProvider(_month),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('The month'),
        actions: <Widget>[
          TextButton(
            onPressed: _pickMonth,
            child: Text(
              DateFormat('MMMM yyyy').format(DateTime.parse('$_month-01')),
            ),
          ),
        ],
      ),
      body: AsyncView<BusinessReport>(
        value: report,
        builder: (BuildContext context, BusinessReport r) => ListView(
          padding: const EdgeInsets.only(bottom: KuboSpacing.xxl),
          children: <Widget>[
            _Headline(report: r),
            _ProfitAndLoss(report: r),
            _MoneyIn(report: r),
            _CashFlow(report: r),
            _WhenBusy(month: _month),
            _GaveAway(month: _month),
          ],
        ),
      ),
    );
  }

  Future<void> _pickMonth() async {
    final DateTime now = ref.read(clockProvider).now();
    final String? picked = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (BuildContext context) => ListView(
        children: <Widget>[
          const SectionHeader('Which month?'),
          for (int back = 0; back < 18; back++)
            Builder(
              builder: (BuildContext context) {
                final DateTime m = DateTime(now.year, now.month - back);
                final String code = DateFormat('yyyy-MM').format(m);
                return ListTile(
                  title: Text(DateFormat('MMMM yyyy').format(m)),
                  selected: code == _month,
                  onTap: () => Navigator.of(context).pop(code),
                );
              },
            ),
        ],
      ),
    );
    if (picked != null) setState(() => _month = picked);
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.report});

  final BusinessReport report;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(KuboSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Took in', style: theme.textTheme.labelMedium),
          MoneyText(report.revenue, emphasised: true),
          const SizedBox(height: KuboSpacing.xs),
          Text(
            report.tradingDays == 0
                ? 'Nothing sold this month'
                : '${report.orderCount} orders · ${report.drinkCount} '
                      'drinks · ${report.tradingDays} trading '
                      '${report.tradingDays == 1 ? 'day' : 'days'}',
            style: theme.textTheme.bodySmall,
          ),
          if (report.perDay != null)
            Text(
              '${report.perDay!.format()} a day · '
              '${report.perOrder!.format()} an order',
              style: theme.textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}

class _ProfitAndLoss extends StatelessWidget {
  const _ProfitAndLoss({required this.report});

  final BusinessReport report;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int? margin = report.grossMarginBp;

    return Column(
      children: <Widget>[
        const SectionHeader('What it made'),
        _Line('Drinks at menu price', report.grossSales),
        if (report.discounts.isPositive)
          _Line('Less discounts', -report.discounts),
        if (report.deliveryFees.isPositive)
          _Line('Delivery charged', report.deliveryFees),
        if (report.refunds.isPositive) _Line('Less refunds', -report.refunds),
        _Line('What you charged', report.netSales, strong: true),
        _Line('Less what the drinks cost to make', -report.cogs),
        _Line(
          'Gross profit',
          report.grossProfit,
          strong: true,
          note: margin == null
              ? null
              : '${(margin / 100).toStringAsFixed(1)}%',
        ),
        if (report.waste.isPositive)
          _Line('Less spilled and thrown away', -report.waste),
        _Line('Trading profit', report.tradingProfit, strong: true),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            KuboSpacing.lg,
            KuboSpacing.sm,
            KuboSpacing.lg,
            KuboSpacing.lg,
          ),
          child: Text(
            'This is profit before the costs of being a shop. Kubo knows '
            'what the coffee cost, from your own recipes — it does not '
            'know your rent, your wifi, or what you pay yourself, because '
            'nothing in the app has ever been told. Take those off this '
            'figure yourself to get what you really earned.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _MoneyIn extends StatelessWidget {
  const _MoneyIn({required this.report});

  final BusinessReport report;

  static const Map<String, String> _names = <String, String>{
    'cash': 'Cash',
    'gcash': 'GCash',
    'maya': 'Maya',
    'maribank': 'MariBank',
    'bpi': 'BPI',
  };

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<MapEntry<String, Money>> rows =
        report.receivedByMethod.entries.toList()
          ..sort(
            (MapEntry<String, Money> a, MapEntry<String, Money> b) =>
                b.value.centavos.compareTo(a.value.centavos),
          );

    return Column(
      children: <Widget>[
        const SectionHeader('Where the money came in'),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.lg),
            child: Text('Nothing yet.', style: theme.textTheme.bodySmall),
          ),
        for (final MapEntry<String, Money> row in rows)
          _Line(_names[row.key] ?? row.key, row.value),
        _Line('Received', report.received, strong: true),
        if (report.stillOwed.isPositive) ...<Widget>[
          _Line('Sold but not yet paid', report.stillOwed),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              KuboSpacing.lg,
              0,
              KuboSpacing.lg,
              KuboSpacing.lg,
            ),
            child: Text(
              'Counted as a sale above, because the coffee is gone. Not '
              'counted as money, because it has not arrived.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ],
    );
  }
}

class _CashFlow extends StatelessWidget {
  const _CashFlow({required this.report});

  final BusinessReport report;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      children: <Widget>[
        const SectionHeader('Cash in and out'),
        _Line('Money received', report.received),
        _Line('Less stock bought', -report.spentOnStock),
        _Line('Net movement', report.netCashMovement, strong: true),
        _Line('On the shelf today, at cost', report.stockOnHand),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            KuboSpacing.lg,
            KuboSpacing.sm,
            KuboSpacing.lg,
            KuboSpacing.lg,
          ),
          child: Text(
            'Not the same as profit, and it is normal for the two to '
            'disagree. A month where you stocked up looks poor here and '
            'fine above, because most of what you bought is still on the '
            'shelf. The shelf figure is today, not the end of the month.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _WhenBusy extends ConsumerWidget {
  const _WhenBusy({required this.month});

  final String month;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final List<BusyPeriod> hours =
        ref.watch(busyByHourProvider(month)).valueOrNull ?? <BusyPeriod>[];
    final List<BusyPeriod> days =
        ref.watch(busyByWeekdayProvider(month)).valueOrNull ?? <BusyPeriod>[];
    if (hours.isEmpty) return const SizedBox.shrink();

    final int busiest = hours
        .map((BusyPeriod h) => h.orderCount)
        .reduce((int a, int b) => a > b ? a : b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const SectionHeader('When you are busy'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.lg),
          child: Column(
            children: <Widget>[
              for (final BusyPeriod h in hours)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    children: <Widget>[
                      SizedBox(
                        width: 52,
                        child: Text(h.label, style: theme.textTheme.bodySmall),
                      ),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: busiest == 0 ? 0 : h.orderCount / busiest,
                            minHeight: 10,
                            backgroundColor: theme.colorScheme.surfaceContainer,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 86,
                        child: Text(
                          '${h.orderCount} · ${h.revenue.format()}',
                          textAlign: TextAlign.right,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: KuboSpacing.md),
        for (final BusyPeriod d in days)
          _Line('${d.label} · ${d.orderCount} orders', d.revenue),
      ],
    );
  }
}

class _GaveAway extends ConsumerWidget {
  const _GaveAway({required this.month});

  final String month;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final List<DiscountGiven> discounts =
        ref.watch(discountsGivenProvider(month)).valueOrNull ??
        <DiscountGiven>[];
    final List<WasteByReason> waste =
        ref.watch(wasteByReasonProvider(month)).valueOrNull ??
        <WasteByReason>[];
    if (discounts.isEmpty && waste.isEmpty) return const SizedBox.shrink();

    return Column(
      children: <Widget>[
        const SectionHeader('What you gave away'),
        for (final DiscountGiven d in discounts)
          _Line('${d.label} · ${d.times}×', -d.total),
        for (final WasteByReason w in waste)
          _Line('${_waste(w.reason)} · ${w.times}×', -w.total),
      ],
    );
  }

  static String _waste(String code) => switch (code) {
    'spill' => 'Spilled',
    'spoiled' => 'Spoiled',
    'expired' => 'Expired',
    'wrong_prep' => 'Made wrong',
    'damaged' => 'Damaged',
    _ => 'Other',
  };
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.amount, {this.strong = false, this.note});

  final String label;
  final Money amount;
  final bool strong;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? style = strong
        ? theme.textTheme.titleSmall
        : theme.textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: KuboSpacing.lg,
        vertical: 5,
      ),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: style)),
          if (note != null) ...<Widget>[
            Text(note!, style: theme.textTheme.bodySmall),
            const SizedBox(width: KuboSpacing.sm),
          ],
          Text(amount.format(), style: style),
        ],
      ),
    );
  }
}
