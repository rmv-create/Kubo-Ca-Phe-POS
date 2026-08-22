import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/errors/app_exception.dart';
import '../../../domain/entities/customer.dart';
import '../../../domain/entities/menu.dart';
import '../../../domain/entities/order_draft.dart';
import '../../../shared/widgets/async_view.dart';
import '../state/cart_controller.dart';
import 'product_config_sheet.dart';

/// Find the customer, or don't — a sale is never blocked on one.
///
/// For a regular this is the fastest path in the app: search, tap the name,
/// tap USE USUAL, and their drink is in the order.
class CustomerSheet extends ConsumerStatefulWidget {
  const CustomerSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (BuildContext context) => DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (BuildContext context, ScrollController controller) =>
          const CustomerSheet(),
    ),
  );

  @override
  ConsumerState<CustomerSheet> createState() => _CustomerSheetState();
}

class _CustomerSheetState extends ConsumerState<CustomerSheet> {
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;
  String _query = '';
  Customer? _selected;

  @override
  void initState() {
    super.initState();
    _selected = ref.read(cartProvider).customer;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _query = value);
    });
  }

  void _choose(Customer customer) {
    ref.read(cartProvider.notifier).setCustomer(customer);
    setState(() => _selected = customer);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Customer? selected = _selected;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            KuboSpacing.lg,
            KuboSpacing.sm,
            KuboSpacing.lg,
            KuboSpacing.md,
          ),
          child: Text('CUSTOMER', style: theme.textTheme.labelSmall),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.lg),
          child: TextField(
            controller: _search,
            autofocus: selected == null,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              hintText: 'Name or mobile',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _search.clear();
                        _onQueryChanged('');
                      },
                    ),
            ),
            onChanged: _onQueryChanged,
          ),
        ),
        if (selected != null) _UsualPanel(customer: selected),
        Expanded(
          child: _Results(
            query: _query,
            selectedId: selected?.id,
            onChoose: _choose,
          ),
        ),
        _Footer(
          query: _search.text,
          onGuest: () {
            ref.read(cartProvider.notifier).setCustomer(null);
            Navigator.of(context).maybePop();
          },
        ),
      ],
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({
    required this.query,
    required this.selectedId,
    required this.onChoose,
  });

  final String query;
  final int? selectedId;
  final ValueChanged<Customer> onChoose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Customer>> results = ref.watch(
      customerSearchProvider(query),
    );
    final DateTime now = ref.watch(clockProvider).now();

    return AsyncView<List<Customer>>(
      value: results,
      builder: (BuildContext context, List<Customer> data) {
        if (data.isEmpty) {
          return EmptyState(
            icon: Icons.person_search_outlined,
            title: query.isEmpty ? 'No customers yet' : 'Nobody found',
            message: query.isEmpty
                ? 'Add one below, or carry on as a guest.'
                : 'Add "$query" below, or carry on as a guest.',
          );
        }
        return ListView.builder(
          itemCount: data.length,
          itemBuilder: (BuildContext context, int index) {
            final Customer customer = data[index];
            return _CustomerTile(
              customer: customer,
              isSelected: customer.id == selectedId,
              now: now,
              onTap: () => onChoose(customer),
            );
          },
        );
      },
    );
  }
}

class _CustomerTile extends StatelessWidget {
  const _CustomerTile({
    required this.customer,
    required this.isSelected,
    required this.now,
    required this.onTap,
  });

  final Customer customer;
  final bool isSelected;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListTile(
      selected: isSelected,
      selectedTileColor: theme.colorScheme.secondaryContainer,
      leading: CircleAvatar(
        backgroundColor: isSelected
            ? theme.colorScheme.primary
            : theme.colorScheme.surfaceContainerHighest,
        child: Text(
          customer.initials,
          style: theme.textTheme.labelMedium?.copyWith(
            color: isSelected
                ? theme.colorScheme.onPrimary
                : theme.colorScheme.onSurface,
          ),
        ),
      ),
      title: Text(customer.name),
      subtitle: Text(
        <String>[
          if (customer.mobile != null) customer.maskedMobile,
          '${customer.visitCount} visit${customer.visitCount == 1 ? '' : 's'}',
          customer.totalSpend.format(),
        ].join(' · '),
      ),
      trailing: _SegmentTag(segment: customer.segmentAt(now)),
      onTap: onTap,
    );
  }
}

class _SegmentTag extends StatelessWidget {
  const _SegmentTag({required this.segment});

  final CustomerSegment segment;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool warn = segment == CustomerSegment.atRisk;
    final Color color = warn
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(KuboRadius.pill),
      ),
      child: Text(
        segment.label.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

/// The usual, and the two ways to use it.
class _UsualPanel extends ConsumerWidget {
  const _UsualPanel({required this.customer});

  final Customer customer;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<UsualOrder?> usual = ref.watch(
      usualOrderProvider(customer.id),
    );
    final ThemeData theme = Theme.of(context);

    return usual.maybeWhen(
      orElse: () => const SizedBox.shrink(),
      data: (UsualOrder? data) {
        if (data == null) {
          return Padding(
            padding: const EdgeInsets.all(KuboSpacing.lg),
            child: Text(
              customer.orderCount == 0
                  ? '${customer.name} has not ordered before.'
                  : 'No usual yet — the same drink has to come up more than '
                        'once before it counts as one.',
              style: theme.textTheme.bodySmall,
            ),
          );
        }
        return Container(
          margin: const EdgeInsets.all(KuboSpacing.lg),
          padding: const EdgeInsets.all(KuboSpacing.lg),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(KuboRadius.lg),
            border: Border.all(color: theme.colorScheme.primary, width: 2),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                data.isSaved
                    ? 'SAVED USUAL'
                    : 'USUAL · ORDERED ${data.pattern.occurrenceCount} TIMES',
                style: theme.textTheme.labelSmall,
              ),
              const SizedBox(height: KuboSpacing.xs),
              Text(
                data.title.toUpperCase(),
                style: theme.textTheme.titleMedium,
              ),
              if (data.subtitle.isNotEmpty)
                Text(data.subtitle, style: theme.textTheme.bodySmall),
              const SizedBox(height: KuboSpacing.md),
              Row(
                children: <Widget>[
                  Expanded(
                    child: FilledButton(
                      onPressed: () => _useUsual(context, ref, data),
                      child: const Text('USE USUAL'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: KuboSpacing.sm),
              OutlinedButton(
                onPressed: () => _useUsual(context, ref, data, modify: true),
                child: const Text('USE USUAL + MODIFY'),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Copies the usual into the order. Modifying it afterwards never rewrites
  /// what is saved — that only changes on an explicit Save as usual.
  Future<void> _useUsual(
    BuildContext context,
    WidgetRef ref,
    UsualOrder usual, {
    bool modify = false,
  }) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    final Product? product = await ref
        .read(menuRepositoryProvider)
        .productById(usual.pattern.productId);
    final ProductSize? size = product?.sizes
        .where((ProductSize s) => s.size.id == usual.pattern.sizeId)
        .firstOrNull;

    if (product == null || size == null) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('That drink is no longer on the menu.')),
        );
      return;
    }

    if (modify) {
      navigator.pop();
      if (!context.mounted) return;
      await ProductConfigSheet.show(
        context,
        product: product,
        initialSize: size,
        initialOptionIds: usual.pattern.optionIds.toSet(),
      );
      return;
    }

    final List<DraftOption> options = await _resolveOptions(
      ref,
      productId: product.id,
      sizeId: size.size.id,
      optionIds: usual.pattern.optionIds,
    );
    ref
        .read(cartProvider.notifier)
        .addItem(product: product, size: size, options: options);
    navigator.pop();
  }

  Future<List<DraftOption>> _resolveOptions(
    WidgetRef ref, {
    required int productId,
    required int sizeId,
    required List<int> optionIds,
  }) async {
    if (optionIds.isEmpty) return <DraftOption>[];
    final List<ResolvedCustomizationGroup> groups = await ref
        .read(menuRepositoryProvider)
        .resolvedGroupsFor(productId, sizeId: sizeId);
    return <DraftOption>[
      for (final ResolvedCustomizationGroup g in groups)
        for (final CustomizationOption o in g.group.activeOptions)
          if (optionIds.contains(o.id))
            DraftOption(
              group: g.group,
              option: o,
              isDefault: g.defaultOptionIds.contains(o.id),
            ),
    ];
  }
}

class _Footer extends ConsumerWidget {
  const _Footer({required this.query, required this.onGuest});

  final String query;
  final VoidCallback onGuest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: theme.colorScheme.outline)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(KuboSpacing.lg),
          child: Column(
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: () => _addCustomer(context, ref, query),
                icon: const Icon(Icons.person_add_outlined),
                label: Text(
                  query.trim().isEmpty ? 'Add a customer' : 'Add "$query"',
                ),
              ),
              const SizedBox(height: KuboSpacing.sm),
              TextButton(
                onPressed: onGuest,
                child: const Text('Continue as guest'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _addCustomer(
    BuildContext context,
    WidgetRef ref,
    String initialName,
  ) async {
    final TextEditingController name = TextEditingController(
      text: initialName.trim(),
    );
    final TextEditingController mobile = TextEditingController();

    final bool? save = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('New customer'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: KuboSpacing.md),
            TextField(
              controller: mobile,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Mobile',
                helperText: 'Optional',
              ),
            ),
          ],
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

    final String finalName = name.text;
    final String finalMobile = mobile.text;
    name.dispose();
    mobile.dispose();
    if (save != true || !context.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    try {
      final int id = await ref
          .read(customerRepositoryProvider)
          .create(name: finalName, mobile: finalMobile);
      final Customer? created = await ref
          .read(customerRepositoryProvider)
          .byId(id);
      ref.read(cartProvider.notifier).setCustomer(created);
      ref.read(salesRevisionProvider.notifier).bump();
      navigator.pop();
    } on AppException catch (error) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}
