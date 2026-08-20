import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/errors/app_exception.dart';
import '../../../domain/entities/customer.dart';
import '../../../domain/entities/reporting.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/money_text.dart';
import '../../../shared/widgets/section_header.dart';
import '../../menu/state/menu_actions.dart';

/// Who comes in, what they order, and what they are worth.
class CustomersScreen extends ConsumerStatefulWidget {
  const CustomersScreen({super.key});

  @override
  ConsumerState<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends ConsumerState<CustomersScreen> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _query = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Customer>> results = ref.watch(
      customerSearchProvider(_query),
    );
    final DateTime now = ref.watch(clockProvider).now();

    return Scaffold(
      appBar: AppBar(title: const Text('Customers')),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(KuboSpacing.lg),
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(
                hintText: 'Name or mobile',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: _onChanged,
            ),
          ),
          Expanded(
            child: AsyncView<List<Customer>>(
              value: results,
              builder: (BuildContext context, List<Customer> data) {
                if (data.isEmpty) {
                  return const EmptyState(
                    icon: Icons.people_outline,
                    title: 'No customers yet',
                    message:
                        'Customers are added from the POS while you take '
                        'an order.',
                  );
                }
                return ListView.separated(
                  itemCount: data.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (BuildContext context, int index) {
                    final Customer c = data[index];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                        child: Text(
                          c.initials,
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ),
                      title: Text(c.name),
                      subtitle: Text(
                        '${c.orderCount} order${c.orderCount == 1 ? '' : 's'} · '
                        '${c.segmentAt(now).label}',
                      ),
                      trailing: MoneyText(c.totalSpend),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext context) =>
                              CustomerDetailScreen(customerId: c.id),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class CustomerDetailScreen extends ConsumerWidget {
  const CustomerDetailScreen({required this.customerId, super.key});

  final int customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<UsualOrder?> usual = ref.watch(
      usualOrderProvider(customerId),
    );
    final ThemeData theme = Theme.of(context);

    return FutureBuilder<Customer?>(
      future: ref.watch(customerRepositoryProvider).byId(customerId),
      builder: (BuildContext context, AsyncSnapshot<Customer?> snapshot) {
        final Customer? customer = snapshot.data;
        if (customer == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: CircularProgressIndicator.adaptive()),
          );
        }
        final DateTime now = ref.watch(clockProvider).now();

        return Scaffold(
          appBar: AppBar(
            title: Text(customer.name),
            actions: <Widget>[
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Edit',
                onPressed: () => _edit(context, ref, customer),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
            children: <Widget>[
              const SectionHeader('History'),
              _Stat(label: 'Visits', value: '${customer.visitCount}'),
              _Stat(label: 'Orders', value: '${customer.orderCount}'),
              _Stat(label: 'Drinks', value: '${customer.itemCount}'),
              _Stat(
                label: 'Total spend',
                value: customer.totalSpend.format(),
                emphasise: true,
              ),
              _Stat(
                label: 'Average order',
                value: customer.averageOrderValue.format(),
              ),
              _Stat(label: 'Segment', value: customer.segmentAt(now).label),
              if (customer.mobile != null)
                _Stat(label: 'Mobile', value: customer.mobile!),
              if (customer.lastVisitAt != null)
                _Stat(
                  label: 'Last visit',
                  value: customer.lastVisitAt!.toLocal().toString().substring(
                    0,
                    16,
                  ),
                ),
              const SectionHeader('Their usual'),
              AsyncView<UsualOrder?>(
                value: usual,
                builder: (BuildContext context, UsualOrder? u) => u == null
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: KuboSpacing.lg,
                        ),
                        child: Text(
                          customer.orderCount == 0
                              ? 'They have not ordered yet.'
                              : 'No usual yet — a drink has to come up more '
                                    'than once before it counts as one.',
                          style: theme.textTheme.bodySmall,
                        ),
                      )
                    : ListTile(
                        leading: Icon(
                          u.isSaved ? Icons.push_pin : Icons.repeat,
                          color: theme.colorScheme.secondary,
                        ),
                        title: Text(u.title),
                        subtitle: Text(
                          <String>[
                            if (u.subtitle.isNotEmpty) u.subtitle,
                            u.isSaved
                                ? 'Saved by you'
                                : 'Ordered ${u.pattern.occurrenceCount} times',
                            u.price.format(),
                          ].join(' · '),
                        ),
                        trailing: u.isSaved
                            ? TextButton(
                                onPressed: () => _clearUsual(context, ref),
                                child: const Text('Unpin'),
                              )
                            : TextButton(
                                onPressed: () =>
                                    _saveUsual(context, ref, u.pattern.id),
                                child: const Text('Pin'),
                              ),
                      ),
              ),
              const SectionHeader('What they order'),
              _Patterns(customerId: customerId),
              const SectionHeader('Recent orders'),
              _CustomerOrders(customerId: customerId),
            ],
          ),
        );
      },
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Customer customer,
  ) async {
    final String? name = await promptForText(
      context,
      title: 'Name',
      label: 'Name',
      initial: customer.name,
    );
    if (name == null || !context.mounted) return;
    final String? mobile = await promptForText(
      context,
      title: 'Mobile',
      label: 'Mobile',
      initial: customer.mobile ?? '',
      helper: 'Optional',
    );
    if (!context.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(customerRepositoryProvider)
          .update(
            Customer(
              id: customer.id,
              name: name,
              mobile: mobile,
              createdAt: customer.createdAt,
              firstVisitAt: customer.firstVisitAt,
              lastVisitAt: customer.lastVisitAt,
              visitCount: customer.visitCount,
              orderCount: customer.orderCount,
              itemCount: customer.itemCount,
              totalSpend: customer.totalSpend,
              storedSegment: customer.storedSegment,
              isActive: customer.isActive,
              savedUsualPatternId: customer.savedUsualPatternId,
              notes: customer.notes,
            ),
          );
      ref.read(salesRevisionProvider.notifier).bump();
      messenger
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('Saved')));
    } on AppException catch (error) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _saveUsual(
    BuildContext context,
    WidgetRef ref,
    int patternId,
  ) async {
    await ref
        .read(customerRepositoryProvider)
        .saveUsual(customerId: customerId, patternId: patternId);
    ref.read(salesRevisionProvider.notifier).bump();
  }

  Future<void> _clearUsual(BuildContext context, WidgetRef ref) async {
    await ref.read(customerRepositoryProvider).clearUsual(customerId);
    ref.read(salesRevisionProvider.notifier).bump();
  }
}

class _Patterns extends ConsumerWidget {
  const _Patterns({required this.customerId});

  final int customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(salesRevisionProvider);
    return FutureBuilder<List<CustomerOrderPattern>>(
      future: ref.watch(customerRepositoryProvider).patternsFor(customerId),
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<CustomerOrderPattern>> snapshot,
          ) {
            final List<CustomerOrderPattern> patterns =
                snapshot.data ?? <CustomerOrderPattern>[];
            if (patterns.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.lg),
                child: Text(
                  'Nothing yet.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              );
            }
            return Column(
              children: <Widget>[
                for (final CustomerOrderPattern p in patterns.take(8))
                  ListTile(
                    dense: true,
                    leading: Text(
                      '${p.occurrenceCount}×',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    title: Text('Drink #${p.productId}, size #${p.sizeId}'),
                    subtitle: Text(
                      'Last ordered '
                      '${p.lastOrderedAt.toLocal().toString().substring(0, 10)}',
                    ),
                  ),
              ],
            );
          },
    );
  }
}

class _CustomerOrders extends ConsumerWidget {
  const _CustomerOrders({required this.customerId});

  final int customerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(salesRevisionProvider);
    return FutureBuilder<List<OrderRecord>>(
      future: ref
          .watch(salesServiceProvider)
          .orders(customerId: customerId, limit: 20),
      builder:
          (BuildContext context, AsyncSnapshot<List<OrderRecord>> snapshot) {
            final List<OrderRecord> orders = snapshot.data ?? <OrderRecord>[];
            if (orders.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.lg),
                child: Text(
                  'No orders yet.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              );
            }
            return Column(
              children: <Widget>[
                for (final OrderRecord o in orders)
                  ListTile(
                    dense: true,
                    title: Text(o.orderNo),
                    subtitle: Text(
                      '${o.businessDate} · ${o.itemCount} '
                      'drink${o.itemCount == 1 ? '' : 's'}'
                      '${o.isVoided ? ' · voided' : ''}',
                    ),
                    trailing: MoneyText(o.total),
                  ),
              ],
            );
          },
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
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
            style: emphasise
                ? theme.textTheme.titleMedium
                : theme.textTheme.bodyLarge,
          ),
        ],
      ),
    );
  }
}
