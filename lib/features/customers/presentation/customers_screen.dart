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
import 'lapsed_screen.dart';
import 'statement_screen.dart';

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
      appBar: AppBar(
        title: const Text('Customers'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.person_search_outlined),
            tooltip: 'Who stopped coming',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const LapsedScreen(),
              ),
            ),
          ),
        ],
      ),
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
              if (customer.firstVisitAt != null)
                _Stat(
                  label: 'First came in',
                  value: _when(customer.firstVisitAt!),
                ),
              if (customer.lastVisitAt != null)
                _Stat(label: 'Last order', value: _when(customer.lastVisitAt!)),

              const SectionHeader('Worth remembering'),
              ListTile(
                leading: const Icon(Icons.cake_outlined),
                title: const Text('Birthday'),
                subtitle: Text(
                  customer.birthdayLabel ??
                      'Not set \u2014 optional, and most never will be',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _editBirthday(context, ref, customer),
              ),
              ListTile(
                leading: const Icon(Icons.sticky_note_2_outlined),
                title: const Text('Notes'),
                subtitle: Text(
                  customer.notes?.trim().isNotEmpty ?? false
                      ? customer.notes!
                      : 'Allergies, how they like it, where they work',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _editNotes(context, ref, customer),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.star_outline),
                value: customer.storedSegment == CustomerSegment.vip,
                title: const Text('VIP'),
                subtitle: const Text(
                  'Marks them by hand, whatever the figures say',
                ),
                onChanged: (_) => _toggleVip(context, ref, customer),
              ),
              Padding(
                padding: const EdgeInsets.all(KuboSpacing.lg),
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) =>
                          StatementScreen(customerId: customer.id),
                    ),
                  ),
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: const Text('Statement of account'),
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

    await _save(
      context,
      ref,
      customer.copyWith(
        name: name,
        mobile: mobile,
        clearMobile: (mobile ?? '').trim().isEmpty,
      ),
    );
  }

  /// Writes one changed customer, and says so.
  ///
  /// Everything that edits a customer goes through here with a `copyWith`,
  /// rather than rebuilding the whole record by hand — which is how a
  /// birthday or a note gets quietly wiped by a rename.
  Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    Customer changed,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(customerRepositoryProvider).update(changed);
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

  /// A birthday, month and day only. There is no year to ask for.
  Future<void> _editBirthday(
    BuildContext context,
    WidgetRef ref,
    Customer customer,
  ) async {
    const List<String> months = <String>[
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    final int? month = await showModalBottomSheet<int>(
      context: context,
      useSafeArea: true,
      builder: (BuildContext context) => ListView(
        children: <Widget>[
          const SectionHeader('Which month?'),
          for (int m = 1; m <= 12; m++)
            ListTile(
              title: Text(months[m - 1]),
              onTap: () => Navigator.of(context).pop(m),
            ),
          if (customer.birthday != null)
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Remove the birthday'),
              onTap: () => Navigator.of(context).pop(0),
            ),
        ],
      ),
    );
    if (month == null || !context.mounted) return;
    if (month == 0) {
      await _save(context, ref, customer.copyWith(clearBirthday: true));
      return;
    }

    final int? day = await showModalBottomSheet<int>(
      context: context,
      useSafeArea: true,
      builder: (BuildContext context) => ListView(
        children: <Widget>[
          SectionHeader('Which day of ${months[month - 1]}?'),
          for (int d = 1; d <= _daysIn(month); d++)
            ListTile(
              title: Text('$d'),
              onTap: () => Navigator.of(context).pop(d),
            ),
        ],
      ),
    );
    if (day == null || !context.mounted) return;

    await _save(
      context,
      ref,
      customer.copyWith(
        birthday:
            '${month.toString().padLeft(2, '0')}-'
            '${day.toString().padLeft(2, '0')}',
      ),
    );
  }

  /// February gets 29 because a birthday has no year to rule it out.
  static int _daysIn(int month) =>
      <int>[31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1];

  Future<void> _editNotes(
    BuildContext context,
    WidgetRef ref,
    Customer customer,
  ) async {
    final String? notes = await promptForText(
      context,
      title: 'Notes',
      label: 'Anything worth remembering',
      initial: customer.notes ?? '',
      helper: 'Allergies, how she likes it, where she works',
    );
    if (notes == null || !context.mounted) return;
    await _save(
      context,
      ref,
      customer.copyWith(notes: notes, clearNotes: notes.trim().isEmpty),
    );
  }

  Future<void> _toggleVip(
    BuildContext context,
    WidgetRef ref,
    Customer customer,
  ) async {
    final bool vip = customer.storedSegment == CustomerSegment.vip;
    await _save(
      context,
      ref,
      customer.copyWith(
        storedSegment: vip ? CustomerSegment.regular : CustomerSegment.vip,
      ),
    );
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

/// A moment, in words rather than in ISO.
String _when(DateTime at) {
  final DateTime local = at.toLocal();
  const List<String> months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${local.day} ${months[local.month - 1]} ${local.year}';
}
