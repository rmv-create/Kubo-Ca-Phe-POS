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
      customerDirectoryProvider(_query),
    );
    final DateTime now = ref.watch(clockProvider).now();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Customers'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.archive_outlined),
            tooltip: 'Archived',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const ArchivedScreen(),
              ),
            ),
          ),
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addCustomer(context, ref),
        icon: const Icon(Icons.person_add_alt),
        label: const Text('Add a customer'),
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
                        'Add one here, or from the POS while you take an '
                        'order.',
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
                      // The note is how she tells two people called James
                      // apart, so it belongs beside the name wherever she
                      // has to choose between them.
                      title: Text(
                        c.notes == null ? c.name : '${c.name} · ${c.notes}',
                      ),
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

/// Adds somebody she knows is coming, without waiting for them to order.
///
/// The note is offered at the same moment rather than later, because the
/// moment she needs it is the moment there are two of them: a second James
/// cannot be saved at all until one of them has a note.
Future<void> _addCustomer(BuildContext context, WidgetRef ref) async {
  final TextEditingController name = TextEditingController();
  final TextEditingController mobile = TextEditingController();
  final TextEditingController notes = TextEditingController();

  final bool? save = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('New customer'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: KuboSpacing.sm),
            TextField(
              controller: mobile,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Mobile',
                helperText: 'Optional',
              ),
            ),
            const SizedBox(height: KuboSpacing.sm),
            TextField(
              controller: notes,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Note',
                helperText:
                    'Only you see this \u2014 never on a receipt. '
                    '"Office", "classmate".',
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Add'),
        ),
      ],
    ),
  );

  if (save != true || !context.mounted) {
    name.dispose();
    mobile.dispose();
    notes.dispose();
    return;
  }

  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  try {
    await ref
        .read(customerRepositoryProvider)
        .create(name: name.text, mobile: mobile.text, notes: notes.text);
    ref.read(customerRevisionProvider.notifier).bump();
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text('${name.text.trim()} added')));
  } on AppException catch (error) {
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(error.message)));
  } finally {
    name.dispose();
    mobile.dispose();
    notes.dispose();
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
                      : 'Never on a receipt. How they like it, or which '
                            'James this is \u2014 "office", "classmate"',
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
              // Archiving is the one she will want almost every time:
              // somebody who stopped coming, whose spend she still wants in
              // the books. Deleting is for a row that should not exist.
              const SectionHeader('Remove them'),
              ListTile(
                leading: Icon(
                  customer.isActive
                      ? Icons.archive_outlined
                      : Icons.unarchive_outlined,
                  color: theme.colorScheme.secondary,
                ),
                title: Text(customer.isActive ? 'Archive' : 'Put back'),
                subtitle: Text(
                  customer.isActive
                      ? 'Takes them off the list. Everything they bought '
                            'stays on the books, and you can put them back.'
                      : 'They are archived. This puts them back on the list.',
                ),
                onTap: () => _archiveOrRestore(context, ref, customer),
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: theme.colorScheme.error,
                ),
                title: const Text('Delete'),
                subtitle: Text(
                  customer.orderCount == 0
                      ? 'They have bought nothing, so nothing is lost.'
                      : 'What they bought stays on the books, but stops '
                            'being theirs. This cannot be undone.',
                ),
                onTap: () => _deleteCustomer(context, ref, customer),
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
      helper:
          'Never printed on a receipt. Use it to tell two people with the '
          'same name apart \u2014 "office", "classmate".',
    );
    if (notes == null || !context.mounted) return;
    await _save(
      context,
      ref,
      customer.copyWith(notes: notes, clearNotes: notes.trim().isEmpty),
    );
  }

  Future<void> _archiveOrRestore(
    BuildContext context,
    WidgetRef ref,
    Customer customer,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      if (customer.isActive) {
        await ref.read(customerRepositoryProvider).archive(customer.id);
      } else {
        await ref.read(customerRepositoryProvider).restore(customer.id);
      }
      ref.read(customerRevisionProvider.notifier).bump();
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: Text(
              customer.isActive
                  ? '${customer.name} archived'
                  : '${customer.name} is back on the list',
            ),
          ),
        );
    } on AppException catch (error) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _deleteCustomer(
    BuildContext context,
    WidgetRef ref,
    Customer customer,
  ) async {
    final bool sure =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: Text('Delete ${customer.name}?'),
            content: Text(
              customer.orderCount == 0
                  ? 'They have bought nothing, so nothing is lost.\n\n'
                        'This cannot be undone.'
                  : 'Their ${customer.orderCount} '
                        'order${customer.orderCount == 1 ? '' : 's'} stay on '
                        'the books \u2014 the money came in either way \u2014 '
                        'but stop being theirs.\n\nArchiving keeps them and '
                        'their history. This cannot be undone.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Keep them'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!sure || !context.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    try {
      await ref.read(customerRepositoryProvider).delete(customer.id);
      ref.read(customerRevisionProvider.notifier).bump();
      ref.read(salesRevisionProvider.notifier).bump();
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text('${customer.name} deleted')));
      navigator.pop();
    } on AppException catch (error) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    }
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
          .orders(customerId: customerId, limit: 20, includeVoided: false),
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

/// The customers she has taken off the list.
///
/// Its own screen rather than a filter on the main one, because the list she
/// searches while serving should never offer somebody she archived.
class ArchivedScreen extends ConsumerWidget {
  const ArchivedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Customer>> archived = ref.watch(
      archivedCustomersProvider,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Archived')),
      body: AsyncView<List<Customer>>(
        value: archived,
        builder: (BuildContext context, List<Customer> data) {
          if (data.isEmpty) {
            return const EmptyState(
              icon: Icons.archive_outlined,
              title: 'Nobody is archived',
              message:
                  'Archiving takes somebody off the list without losing '
                  'what they bought.',
            );
          }
          return ListView.separated(
            itemCount: data.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (BuildContext context, int index) {
              final Customer c = data[index];
              return ListTile(
                leading: const Icon(Icons.person_outline),
                title: Text(
                  c.notes == null ? c.name : '${c.name} · ${c.notes}',
                ),
                subtitle: Text(
                  '${c.orderCount} order${c.orderCount == 1 ? '' : 's'} · '
                  '${c.totalSpend.format()}',
                ),
                trailing: TextButton(
                  onPressed: () => _putBack(context, ref, c),
                  child: const Text('Put back'),
                ),
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
    );
  }

  Future<void> _putBack(
    BuildContext context,
    WidgetRef ref,
    Customer customer,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(customerRepositoryProvider).restore(customer.id);
      ref.read(customerRevisionProvider.notifier).bump();
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text('${customer.name} is back on the list')),
        );
    } on AppException catch (error) {
      // Most likely somebody with that name took their place while they
      // were away, and the note no longer tells them apart.
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}
