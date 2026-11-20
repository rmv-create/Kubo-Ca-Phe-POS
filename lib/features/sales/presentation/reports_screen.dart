import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/money/money.dart';
import '../../../data/db/archive_file.dart';
import '../../../data/export/excel_export_service.dart';
import '../../../domain/entities/reporting.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/money_text.dart';
import '../../../shared/widgets/section_header.dart';

/// Today, this month, and which drinks are actually earning.
class ReportsScreen extends ConsumerWidget {
  const ReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String today = ref.watch(todayBusinessDateProvider);
    final ReportPeriod period = ref.watch(reportWindowProvider);

    final AsyncValue<SalesSummary> summary = ref.watch(
      periodSummaryProvider(period),
    );
    final AsyncValue<List<ProductPerformance>> sellers = ref.watch(
      periodBestSellersProvider(period),
    );
    final AsyncValue<List<ProductPerformance>> profitable = ref.watch(
      periodMostProfitableProvider(period),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: <Widget>[
          // Two ways out, named, rather than one that silently does
          // nothing when the share sheet is waved away — which is what
          // "exporting is not available" turned out to be.
          PopupMenuButton<bool>(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Export to Excel',
            onSelected: (bool share) => _export(context, ref, share: share),
            itemBuilder: (BuildContext context) => <PopupMenuEntry<bool>>[
              const PopupMenuItem<bool>(
                value: true,
                child: ListTile(
                  leading: Icon(Icons.ios_share),
                  title: Text('Share'),
                  subtitle: Text('To Drive, Sheets, Messenger'),
                ),
              ),
              const PopupMenuItem<bool>(
                value: false,
                child: ListTile(
                  leading: Icon(Icons.download_outlined),
                  title: Text('Save to this phone'),
                  subtitle: Text('Into Downloads'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
        children: <Widget>[
          _PeriodPicker(today: today),
          SectionHeader(period.label),
          AsyncView<SalesSummary>(
            value: summary,
            builder: (BuildContext context, SalesSummary s) => Column(
              children: <Widget>[
                SummaryCard(summary: s),
                if (s.orderCount > 0)
                  _StatRow(
                    label: 'Average order',
                    value: s.averageOrderValue.format(),
                  ),
              ],
            ),
          ),
          const SectionHeader('Best sellers'),
          AsyncView<List<ProductPerformance>>(
            value: sellers,
            builder: (BuildContext context, List<ProductPerformance> list) =>
                _PerformanceList(
                  products: list,
                  emptyMessage: 'Nothing sold in this stretch.',
                ),
          ),
          const SectionHeader('Most profitable'),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              KuboSpacing.lg,
              0,
              KuboSpacing.lg,
              KuboSpacing.sm,
            ),
            child: Text(
              'Ranked by what each one actually earns. This is rarely the same '
              'order as best sellers \u2014 that is the point of showing both.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          AsyncView<List<ProductPerformance>>(
            value: profitable,
            builder: (BuildContext context, List<ProductPerformance> list) =>
                _PerformanceList(
                  products: list,
                  showProfit: true,
                  emptyMessage:
                      'Nothing can be ranked by profit yet \u2014 the drinks '
                      'sold so far have no recipe or an ingredient with no '
                      'price.',
                ),
          ),
        ],
      ),
    );
  }

  Future<void> _export(
    BuildContext context,
    WidgetRef ref, {
    required bool share,
  }) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(content: Text('Building the reports\u2026')),
      );
    try {
      // One workbook with every sheet in it, handed to the share sheet.
      // This used to write eight files into a folder, and a browser has no
      // folder — so in the only build she actually runs, the export simply
      // failed. One file is also kinder: she taps Share once, not eight
      // times, and tabs between sheets in Google Sheets rather than
      // between downloads.
      final ExcelBook book = await ref.read(excelExportProvider).everything();
      final bool shared = await saveBinary(
        book.bytes,
        book.name,
        into: ref.read(backupServiceProvider).backupDirectory,
        mimeType:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        shareFirst: share,
      );
      if (!shared) return;
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              share
                  ? '${book.name} is ready'
                  : '${book.name} saved to this phone',
            ),
          ),
        );
    } on Object catch (error) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('The export failed: $error')));
    }
  }
}

/// The block of figures that appears on Reports and on Daily closing.
class SummaryCard extends StatelessWidget {
  const SummaryCard({required this.summary, super.key});

  final SalesSummary summary;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (summary.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.lg),
        child: Text('Nothing recorded yet.', style: theme.textTheme.bodySmall),
      );
    }

    return Column(
      children: <Widget>[
        _StatRow(label: 'Orders', value: '${summary.orderCount}'),
        _StatRow(label: 'Drinks', value: '${summary.drinkCount}'),
        // The coffee money and the rider's money are two different things.
        // She pays the rider directly, so the fare passes through her hands
        // and does not stop there: showing them added together was telling
        // her she had earned money that was never hers.
        _StatRow(
          label: 'Sales',
          value: summary.salesRevenue.format(),
          emphasise: true,
        ),
        if (summary.deliveryCollected.isPositive) ...<Widget>[
          _StatRow(
            label: 'Delivery collected',
            value: summary.deliveryCollected.format(),
          ),
          _StatRow(label: 'Taken altogether', value: summary.revenue.format()),
        ],
        for (final MapEntry<String, Money> row
            in summary.byMethod.entries.toList()..sort(
              (MapEntry<String, Money> a, MapEntry<String, Money> b) =>
                  b.value.centavos.compareTo(a.value.centavos),
            ))
          _StatRow(label: _methodName(row.key), value: row.value.format()),
        // Shown only when there is some, and immediately under the two
        // figures it explains the gap in.
        if (summary.unpaid.isPositive)
          _StatRow(
            label:
                'Still owed · '
                '${summary.unpaidOrderCount} '
                'order${summary.unpaidOrderCount == 1 ? '' : 's'}',
            value: summary.unpaid.format(),
          ),
        const Divider(indent: KuboSpacing.lg, endIndent: KuboSpacing.lg),
        _StatRow(label: 'Cost of goods', value: summary.cogs.format()),
        _StatRow(
          label: 'Gross profit',
          value: summary.grossProfit.format(),
          emphasise: true,
        ),
        _StatRow(label: 'Gross margin', value: summary.marginLabel),
        const Divider(indent: KuboSpacing.lg, endIndent: KuboSpacing.lg),
        _StatRow(label: 'Waste', value: summary.waste.format()),
        _StatRow(label: 'Refunds', value: summary.refunds.format()),
        _StatRow(label: 'Voids', value: summary.voids.format()),
        if (summary.uncostedOrders > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              KuboSpacing.lg,
              KuboSpacing.sm,
              KuboSpacing.lg,
              0,
            ),
            child: Text(
              '${summary.uncostedOrders} '
              'order${summary.uncostedOrders == 1 ? '' : 's'} could not be '
              'costed, so gross profit is understated. Add the missing recipes '
              'and ingredient prices to see the real number.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.label,
    required this.value,
    this.emphasise = false,
  });

  final String label;
  final String value;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: KuboSpacing.lg,
        vertical: 6,
      ),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text(
            value,
            style:
                (emphasise
                        ? theme.textTheme.titleMedium
                        : theme.textTheme.bodyLarge)
                    ?.copyWith(
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
          ),
        ],
      ),
    );
  }
}

class _PerformanceList extends StatelessWidget {
  const _PerformanceList({
    required this.products,
    required this.emptyMessage,
    this.showProfit = false,
  });

  final List<ProductPerformance> products;
  final String emptyMessage;
  final bool showProfit;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    if (products.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.lg),
        child: Text(emptyMessage, style: theme.textTheme.bodySmall),
      );
    }
    return Column(
      children: <Widget>[
        for (final ProductPerformance p in products.take(10))
          ListTile(
            dense: true,
            title: Text(p.title),
            subtitle: Text(
              '${p.unitsSold} sold · ${p.revenue.format()}'
              '${p.isCosted ? ' · margin ${p.marginLabel}' : ' · not costed'}',
            ),
            trailing: showProfit && p.isCosted
                ? MoneyText(p.grossProfit)
                : Text('${p.unitsSold}', style: theme.textTheme.titleMedium),
          ),
      ],
    );
  }
}

/// The codes payments carry, in the words on the buttons.
String _methodName(String code) => switch (code) {
  'cash' => 'Cash',
  'gcash' => 'GCash',
  'maya' => 'Maya',
  'maribank' => 'MariBank',
  'bpi' => 'BPI',
  _ => code,
};

/// Which stretch of trading the figures below cover.
///
/// Always on screen, because the question "how did today go" and the
/// question "how is the month going" get asked at different moments and
/// neither should need hunting for. The four she asked for: the day she is
/// in, the month she is in, a stretch she picks, and everything.
class _PeriodPicker extends ConsumerWidget {
  const _PeriodPicker({required this.today});

  final String today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ReportPeriod period = ref.watch(reportWindowProvider);
    final ReportWindow window = ref.read(reportWindowProvider.notifier);
    final String month = today.substring(0, 7);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        KuboSpacing.lg,
        KuboSpacing.md,
        KuboSpacing.lg,
        0,
      ),
      child: Wrap(
        spacing: KuboSpacing.sm,
        runSpacing: KuboSpacing.sm,
        children: <Widget>[
          ChoiceChip(
            label: const Text('Today'),
            selected: period == ReportPeriod.day(today),
            onSelected: (_) => window.show(ReportPeriod.day(today)),
          ),
          ChoiceChip(
            label: const Text('This month'),
            selected: period == ReportPeriod.month(month),
            onSelected: (_) => window.show(ReportPeriod.month(month)),
          ),
          ChoiceChip(
            label: Text(
              period.kind == ReportPeriodKind.between
                  ? period.label
                  : 'Choose dates',
            ),
            avatar: const Icon(Icons.date_range, size: 18),
            selected: period.kind == ReportPeriodKind.between,
            onSelected: (_) => _pickDates(context, ref),
          ),
          ChoiceChip(
            label: const Text('All time'),
            selected: period.kind == ReportPeriodKind.everything,
            onSelected: (_) => window.show(ReportPeriod.everything),
          ),
        ],
      ),
    );
  }

  /// A stretch she chooses herself — last week, a quarter, the days of a
  /// fiesta.
  Future<void> _pickDates(BuildContext context, WidgetRef ref) async {
    final DateTime now = ref.read(clockProvider).now();
    final ReportPeriod current = ref.read(reportWindowProvider);

    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      // The shop cannot have sold anything before it existed, and a date in
      // the future would only ever be a mistyped year.
      firstDate: DateTime(2024),
      lastDate: now,
      initialDateRange: current.kind == ReportPeriodKind.between
          ? DateTimeRange(
              start: DateTime.parse(current.from!),
              end: DateTime.parse(current.to!),
            )
          : null,
      helpText: 'Which days?',
    );
    if (picked == null) return;

    ref
        .read(reportWindowProvider.notifier)
        .show(ReportPeriod.between(_asDate(picked.start), _asDate(picked.end)));
  }

  static String _asDate(DateTime at) =>
      '${at.year.toString().padLeft(4, '0')}-'
      '${at.month.toString().padLeft(2, '0')}-'
      '${at.day.toString().padLeft(2, '0')}';
}
