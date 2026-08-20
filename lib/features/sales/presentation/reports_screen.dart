import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
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
    final String month = today.substring(0, 7);
    final AsyncValue<SalesSummary> day = ref.watch(dailySummaryProvider(today));
    final AsyncValue<SalesSummary> monthly = ref.watch(
      monthlySummaryProvider(month),
    );
    final AsyncValue<List<ProductPerformance>> sellers = ref.watch(
      productPerformanceProvider(month),
    );
    final AsyncValue<List<ProductPerformance>> profitable = ref.watch(
      mostProfitableProvider(month),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reports'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Export to Excel',
            onPressed: () => _export(context, ref),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
        children: <Widget>[
          SectionHeader('Today · $today'),
          AsyncView<SalesSummary>(
            value: day,
            builder: (BuildContext context, SalesSummary s) =>
                SummaryCard(summary: s),
          ),
          SectionHeader('This month · $month'),
          AsyncView<SalesSummary>(
            value: monthly,
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
                  emptyMessage: 'Nothing sold this month yet.',
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
              'order as best sellers — that is the point of showing both.',
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
                      'Nothing can be ranked by profit yet — the drinks sold so '
                      'far have no recipe or an ingredient with no price.',
                ),
          ),
        ],
      ),
    );
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('Building the reports…')));
    try {
      final List<File> files = await ref.read(excelExportProvider).exportAll();
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text('${files.length} spreadsheets saved to Documents'),
            action: SnackBarAction(
              label: 'Share',
              onPressed: () => Share.shareXFiles(
                files.map((File f) => XFile(f.path)).toList(),
                text: 'Kubo Cà Phê reports',
              ),
            ),
          ),
        );
    } catch (error) {
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
        _StatRow(
          label: 'Revenue',
          value: summary.revenue.format(),
          emphasise: true,
        ),
        _StatRow(label: 'Cash', value: summary.cash.format()),
        _StatRow(label: 'GCash', value: summary.gcash.format()),
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
