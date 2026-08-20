import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/money/money.dart';
import '../../../domain/entities/menu.dart';
import '../../../domain/entities/order_draft.dart';
import '../../../shared/widgets/async_view.dart';
import '../state/cart_controller.dart';

/// Configure one drink: size, then whatever choices it actually offers.
///
/// Groups the owner marked "not proactively asking" fold behind **More
/// options**, so the common order is size → ADD. Everything that is offered is
/// still one tap away.
class ProductConfigSheet extends ConsumerStatefulWidget {
  const ProductConfigSheet({
    required this.product,
    this.editingLineId,
    this.initialSize,
    this.initialOptionIds = const <int>{},
    super.key,
  });

  final Product product;

  /// Set when reopening an existing order line to change it.
  final String? editingLineId;

  final ProductSize? initialSize;
  final Set<int> initialOptionIds;

  /// Opens the sheet on iPhone. On iPad the same widget is shown inline.
  static Future<void> show(
    BuildContext context, {
    required Product product,
    String? editingLineId,
    ProductSize? initialSize,
    Set<int> initialOptionIds = const <int>{},
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (BuildContext context) => DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (BuildContext context, ScrollController controller) =>
          ProductConfigSheet(
            product: product,
            editingLineId: editingLineId,
            initialSize: initialSize,
            initialOptionIds: initialOptionIds,
          ),
    ),
  );

  @override
  ConsumerState<ProductConfigSheet> createState() => _ProductConfigSheetState();
}

class _ProductConfigSheetState extends ConsumerState<ProductConfigSheet> {
  ProductSize? _size;
  Set<int> _selected = <int>{};
  bool _initialisedFromDefaults = false;
  bool _showAllGroups = false;

  @override
  void initState() {
    super.initState();
    _size = widget.initialSize ?? widget.product.defaultSize;
    _selected = <int>{...widget.initialOptionIds};
    // When reopening an existing line we honour what was chosen then, rather
    // than resetting to the product's defaults.
    _initialisedFromDefaults = widget.editingLineId != null;
    _showAllGroups = widget.editingLineId != null;
  }

  void _applyDefaults(List<ResolvedCustomizationGroup> groups) {
    if (_initialisedFromDefaults) return;
    _initialisedFromDefaults = true;
    _selected = <int>{
      for (final ResolvedCustomizationGroup g in groups) ...g.defaultOptionIds,
    };
  }

  void _toggle(ResolvedCustomizationGroup group, CustomizationOption option) {
    setState(() {
      if (group.group.selectionType == SelectionType.single) {
        // Tapping the chosen option again clears it, unless one is required.
        final bool alreadyOn = _selected.contains(option.id);
        for (final CustomizationOption o in group.group.activeOptions) {
          _selected.remove(o.id);
        }
        if (!alreadyOn || group.isRequired) _selected.add(option.id);
      } else {
        if (!_selected.remove(option.id)) _selected.add(option.id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<ResolvedCustomizationGroup>> groups = ref.watch(
      _resolvedGroupsProvider((
        productId: widget.product.id,
        sizeId: _size?.size.id,
      )),
    );

    return AsyncView<List<ResolvedCustomizationGroup>>(
      value: groups,
      builder: (BuildContext context, List<ResolvedCustomizationGroup> data) {
        _applyDefaults(data);

        final List<ResolvedCustomizationGroup> visible = data
            .where((ResolvedCustomizationGroup g) => g.isVisible)
            .toList();
        final List<ResolvedCustomizationGroup> upFront = visible
            .where((ResolvedCustomizationGroup g) => g.isProactive)
            .toList();
        final List<ResolvedCustomizationGroup> onRequest = visible
            .where((ResolvedCustomizationGroup g) => !g.isProactive)
            .toList();
        final List<ResolvedCustomizationGroup> shown = _showAllGroups
            ? <ResolvedCustomizationGroup>[...upFront, ...onRequest]
            : upFront;

        final String? missing = _missingRequired(visible);
        final Money price = _price(data);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _Header(product: widget.product),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.lg),
                children: <Widget>[
                  if (widget.product.availableSizes.length > 1)
                    _SizePicker(
                      product: widget.product,
                      selected: _size,
                      onSelected: (ProductSize s) => setState(() => _size = s),
                    ),
                  for (final ResolvedCustomizationGroup group in shown)
                    _GroupPicker(
                      group: group,
                      selected: _selected,
                      onTap: (CustomizationOption o) => _toggle(group, o),
                    ),
                  if (onRequest.isNotEmpty && !_showAllGroups)
                    Padding(
                      padding: const EdgeInsets.only(top: KuboSpacing.lg),
                      child: OutlinedButton.icon(
                        onPressed: () => setState(() => _showAllGroups = true),
                        icon: const Icon(Icons.tune),
                        label: Text(
                          'More options · '
                          '${onRequest.map((ResolvedCustomizationGroup g) => g.group.name).join(', ')}',
                        ),
                      ),
                    ),
                  const SizedBox(height: KuboSpacing.xl),
                ],
              ),
            ),
            _AddBar(
              price: price,
              blocker: _size == null ? 'Choose a size' : missing,
              isEdit: widget.editingLineId != null,
              onAdd: () => _commit(data),
            ),
          ],
        );
      },
    );
  }

  String? _missingRequired(List<ResolvedCustomizationGroup> groups) {
    for (final ResolvedCustomizationGroup g in groups) {
      if (!g.isRequired) continue;
      final bool any = g.group.activeOptions.any(
        (CustomizationOption o) => _selected.contains(o.id),
      );
      if (!any) return 'Choose ${g.group.name.toLowerCase()}';
    }
    return null;
  }

  Money _price(List<ResolvedCustomizationGroup> groups) {
    Money total = _size?.price ?? Money.zero;
    for (final ResolvedCustomizationGroup g in groups) {
      for (final CustomizationOption o in g.group.activeOptions) {
        if (_selected.contains(o.id)) total = total + o.priceDelta;
      }
    }
    return total;
  }

  void _commit(List<ResolvedCustomizationGroup> groups) {
    final ProductSize? size = _size;
    if (size == null) return;

    final List<DraftOption> chosen = <DraftOption>[
      for (final ResolvedCustomizationGroup g in groups)
        for (final CustomizationOption o in g.group.activeOptions)
          if (_selected.contains(o.id)) DraftOption(group: g.group, option: o),
    ];

    final CartController cart = ref.read(cartProvider.notifier);
    final String? editing = widget.editingLineId;
    if (editing != null) {
      final DraftItem? existing = cart.itemById(editing);
      if (existing != null) {
        cart.replaceItem(
          editing,
          existing.copyWith(size: size, options: chosen),
        );
      }
    } else {
      cart.addItem(product: widget.product, size: size, options: chosen);
    }
    Navigator.of(context).maybePop();
  }
}

typedef _GroupKey = ({int productId, int? sizeId});

final _resolvedGroupsProvider =
    FutureProvider.family<List<ResolvedCustomizationGroup>, _GroupKey>((
      Ref ref,
      _GroupKey key,
    ) {
      ref.watch(menuRevisionProvider);
      return ref
          .watch(menuRepositoryProvider)
          .resolvedGroupsFor(key.productId, sizeId: key.sizeId);
    });

class _Header extends StatelessWidget {
  const _Header({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        KuboSpacing.lg,
        KuboSpacing.sm,
        KuboSpacing.lg,
        KuboSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            product.name.toUpperCase(),
            style: theme.textTheme.headlineSmall,
          ),
          if (product.description?.isNotEmpty ?? false) ...<Widget>[
            const SizedBox(height: KuboSpacing.xs),
            Text(product.description!, style: theme.textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

class _SizePicker extends StatelessWidget {
  const _SizePicker({
    required this.product,
    required this.selected,
    required this.onSelected,
  });

  final Product product;
  final ProductSize? selected;
  final ValueChanged<ProductSize> onSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(
            top: KuboSpacing.md,
            bottom: KuboSpacing.sm,
          ),
          child: Text('SIZE', style: theme.textTheme.labelSmall),
        ),
        Row(
          children: <Widget>[
            for (final ProductSize size in product.availableSizes) ...<Widget>[
              Expanded(
                child: _SizeButton(
                  size: size,
                  isSelected: selected?.size.id == size.size.id,
                  onTap: () => onSelected(size),
                ),
              ),
              if (size != product.availableSizes.last)
                const SizedBox(width: KuboSpacing.sm),
            ],
          ],
        ),
      ],
    );
  }
}

class _SizeButton extends StatelessWidget {
  const _SizeButton({
    required this.size,
    required this.isSelected,
    required this.onTap,
  });

  final ProductSize size;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KuboRadius.md),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: KuboSpacing.md),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.secondaryContainer
              : theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(KuboRadius.md),
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
            width: isSelected ? 2 : 1.5,
          ),
        ),
        child: Column(
          children: <Widget>[
            Text(
              size.size.name.toUpperCase(),
              style: theme.textTheme.titleMedium,
            ),
            Text(size.size.volumeLabel, style: theme.textTheme.labelMedium),
            const SizedBox(height: KuboSpacing.xs),
            Text(size.price.format(), style: theme.textTheme.titleSmall),
          ],
        ),
      ),
    );
  }
}

class _GroupPicker extends StatelessWidget {
  const _GroupPicker({
    required this.group,
    required this.selected,
    required this.onTap,
  });

  final ResolvedCustomizationGroup group;
  final Set<int> selected;
  final ValueChanged<CustomizationOption> onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<CustomizationOption> options = group.group.activeOptions;
    if (options.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(
            top: KuboSpacing.lg,
            bottom: KuboSpacing.sm,
          ),
          child: Row(
            children: <Widget>[
              Text(
                group.group.name.toUpperCase(),
                style: theme.textTheme.labelSmall,
              ),
              if (group.isRequired) ...<Widget>[
                const SizedBox(width: KuboSpacing.sm),
                Text(
                  '· REQUIRED',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
        Wrap(
          spacing: KuboSpacing.sm,
          runSpacing: KuboSpacing.sm,
          children: <Widget>[
            for (final CustomizationOption option in options)
              _OptionChip(
                option: option,
                isSelected: selected.contains(option.id),
                onTap: () => onTap(option),
              ),
          ],
        ),
      ],
    );
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({
    required this.option,
    required this.isSelected,
    required this.onTap,
  });

  final CustomizationOption option;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KuboRadius.md),
      child: Container(
        constraints: const BoxConstraints(minHeight: KuboTouch.minTarget),
        padding: const EdgeInsets.symmetric(
          horizontal: KuboSpacing.md,
          vertical: KuboSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(KuboRadius.md),
          border: Border.all(
            color: isSelected
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
            width: isSelected ? 2 : 1.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (isSelected) ...<Widget>[
              Icon(Icons.check, size: 16, color: theme.colorScheme.onPrimary),
              const SizedBox(width: KuboSpacing.xs),
            ],
            Text(
              option.name,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: isSelected ? theme.colorScheme.onPrimary : null,
                fontWeight: isSelected ? FontWeight.w600 : null,
              ),
            ),
            if (!option.priceDelta.isZero) ...<Widget>[
              const SizedBox(width: KuboSpacing.sm),
              Text(
                '+${option.priceDelta.format()}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isSelected
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AddBar extends StatelessWidget {
  const _AddBar({
    required this.price,
    required this.blocker,
    required this.isEdit,
    required this.onAdd,
  });

  final Money price;
  final String? blocker;
  final bool isEdit;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
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
          child: SizedBox(
            height: KuboTouch.primaryAction,
            child: FilledButton(
              onPressed: blocker == null ? onAdd : null,
              child: Text(
                blocker ??
                    '${isEdit ? 'SAVE CHANGES' : 'ADD TO ORDER'} · ${price.format()}',
              ),
            ),
          ),
        ),
      ),
    );
  }
}
