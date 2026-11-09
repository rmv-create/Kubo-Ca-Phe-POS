import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/money/money.dart';
import '../../../data/db/archive_file.dart';
import '../../../domain/entities/customer.dart';
import '../../../domain/entities/reporting.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/money_text.dart';

/// Everything one customer has ever bought, from the first cup to the last.
///
/// Not a bill. Almost everything on it is already paid for; it is the list
/// she hands somebody who asks "how much have I spent here?", or who keeps
/// a tab and wants to see it. What is still owed is called out at the
/// bottom, because that is the only part anybody needs to act on.
class StatementScreen extends ConsumerWidget {
  const StatementScreen({required this.customerId, super.key});

  final int customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(salesRevisionProvider);
    final AsyncValue<Customer?> customer = ref.watch(
      customerByIdProvider(customerId),
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Statement'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: 'Send it to them',
            onPressed: () => _share(context, ref),
          ),
        ],
      ),
      body: AsyncView<Customer?>(
        value: customer,
        builder: (BuildContext context, Customer? who) => who == null
            ? const Center(child: Text('That customer is gone.'))
            : _Body(customer: who),
      ),
    );
  }

  Future<void> _share(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final Customer? who = await ref
          .read(customerRepositoryProvider)
          .byId(customerId);
      if (who == null) return;
      final List<OrderRecord> orders = await ref
          .read(salesServiceProvider)
          .orders(customerId: customerId, limit: 1000);
      final String shop = ref.read(settingsControllerProvider).businessName;

      await saveBinary(
        _asText(shop, who, orders).codeUnits,
        'Statement ${who.name}.txt',
        into: ref.read(backupServiceProvider).backupDirectory,
        mimeType: 'text/plain',
      );
    } on Object catch (error) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  /// Plain text, because it has to survive being pasted into Messenger.
  static String _asText(String shop, Customer who, List<OrderRecord> orders) {
    final StringBuffer out = StringBuffer()
      ..writeln(shop)
      ..writeln('Statement for ${who.name}')
      ..writeln('');
    Money owed = Money.zero;
    for (final OrderRecord o in orders.reversed) {
      final bool unpaid = o.paymentState == 'unpaid';
      if (unpaid) owed += o.total;
      out.writeln(
        '${o.businessDate}  ${o.orderNo}  '
        '${o.itemCount} drink${o.itemCount == 1 ? '' : 's'}  '
        '${o.total.format()}${unpaid ? '  (not yet paid)' : ''}',
      );
    }
    out
      ..writeln('')
      ..writeln('${orders.length} orders, ${who.totalSpend.format()} in all');
    if (owed.isPositive) out.writeln('Still owed: ${owed.format()}');
    return out.toString();
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.customer});

  final Customer customer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);

    return FutureBuilder<List<OrderRecord>>(
      future: ref
          .watch(salesServiceProvider)
          .orders(customerId: customer.id, limit: 1000),
      builder:
          (BuildContext context, AsyncSnapshot<List<OrderRecord>> snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator.adaptive());
            }
            final List<OrderRecord> orders = snapshot.data!;
            final Money owed = orders
                .where((OrderRecord o) => o.paymentState == 'unpaid')
                .fold(Money.zero, (Money a, OrderRecord o) => a + o.total);

            return ListView(
              padding: const EdgeInsets.only(bottom: KuboSpacing.xxl),
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.all(KuboSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(customer.name, style: theme.textTheme.titleLarge),
                      if (customer.mobile != null)
                        Text(
                          customer.mobile!,
                          style: theme.textTheme.bodySmall,
                        ),
                      const SizedBox(height: KuboSpacing.md),
                      Text(
                        '${orders.length} order'
                        '${orders.length == 1 ? '' : 's'} in all',
                        style: theme.textTheme.bodyMedium,
                      ),
                      MoneyText(customer.totalSpend, emphasised: true),
                    ],
                  ),
                ),
                if (owed.isPositive)
                  Container(
                    margin: const EdgeInsets.fromLTRB(
                      KuboSpacing.lg,
                      0,
                      KuboSpacing.lg,
                      KuboSpacing.lg,
                    ),
                    padding: const EdgeInsets.all(KuboSpacing.md),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(KuboRadius.md),
                    ),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          Icons.schedule,
                          size: 20,
                          color: theme.colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: KuboSpacing.sm),
                        Expanded(
                          child: Text(
                            'Still owed: ${owed.format()}',
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (orders.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: KuboSpacing.lg,
                    ),
                    child: Text(
                      'Nothing yet.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                for (final OrderRecord o in orders)
                  ListTile(
                    dense: true,
                    title: Text('${o.businessDate} · ${o.orderNo}'),
                    subtitle: Text(
                      '${o.itemCount} drink${o.itemCount == 1 ? '' : 's'}'
                      '${o.paymentState == 'unpaid' ? ' · not yet paid' : ''}'
                      '${o.status == 'voided' ? ' · voided' : ''}',
                    ),
                    trailing: MoneyText(o.total),
                  ),
              ],
            );
          },
    );
  }
}
