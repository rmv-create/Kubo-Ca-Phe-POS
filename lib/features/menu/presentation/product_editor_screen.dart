import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/money/money.dart';
import '../../../domain/entities/menu.dart';
import '../../../domain/repositories/menu_repository.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/section_header.dart';
import '../state/menu_actions.dart';

/// Everything about one drink: its name, its category, what it costs at each
/// size, which choices it offers, and what is already selected when it is
/// tapped on the POS.
class ProductEditorScreen extends ConsumerWidget {
  const ProductEditorScreen({required this.productId, super.key});

  final int productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<ProductEditorData> data = ref.watch(
      productEditorProvider(productId),
    );

    return Scaffold(
      appBar: AppBar(title: Text(data.valueOrNull?.product?.name ?? 'Drink')),
      body: AsyncView<ProductEditorData>(
        value: data,
        onRetry: () => ref.invalidate(productEditorProvider(productId)),
        builder: (BuildContext context, ProductEditorData d) {
          final Product? product = d.product;
          if (product == null) {
            return const EmptyState(
              icon: Icons.search_off,
              title: 'Drink not found',
              message: 'It may have been deleted.',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
            children: <Widget>[
              const SectionHeader('Details'),
              _DetailTiles(data: d, product: product),
              const SectionHeader('Sizes and prices'),
              _SizesSection(data: d, product: product),
              const SectionHeader('Choices this drink offers'),
              _GroupsSection(data: d, product: product),
              const SectionHeader('Availability'),
              _AvailabilitySection(product: product),
            ],
          );
        },
      ),
    );
  }
}

class _DetailTiles extends ConsumerWidget {
  const _DetailTiles({required this.data, required this.product});

  final ProductEditorData data;
  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MenuRepository repo = ref.watch(menuRepositoryProvider);
    final ProductCategory? category = data.categories
        .where((ProductCategory c) => c.id == product.categoryId)
        .firstOrNull;

    return Column(
      children: <Widget>[
        ListTile(
          leading: const Icon(Icons.label_outline),
          title: const Text('Name'),
          subtitle: Text(product.name),
          onTap: () async {
            final String? name = await promptForText(
              context,
              title: 'Drink name',
              label: 'Name',
              initial: product.name,
            );
            if (name == null || !context.mounted) return;
            await runMenuEdit(
              context,
              ref,
              () => repo.updateProduct(product.copyWith(name: name)),
              successMessage: 'Saved',
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text('Category'),
          subtitle: Text(category?.name ?? 'None'),
          onTap: () async {
            final ProductCategory? picked = await showDialog<ProductCategory>(
              context: context,
              builder: (BuildContext context) => SimpleDialog(
                title: const Text('Category'),
                children: <Widget>[
                  for (final ProductCategory c in data.categories)
                    SimpleDialogOption(
                      onPressed: () => Navigator.of(context).pop(c),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Text(c.name),
                      ),
                    ),
                ],
              ),
            );
            if (picked == null || !context.mounted) return;
            await runMenuEdit(
              context,
              ref,
              () => repo.updateProduct(product.copyWith(categoryId: picked.id)),
              successMessage: 'Moved to ${picked.name}',
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.notes_outlined),
          title: const Text('Description'),
          subtitle: Text(
            product.description?.isNotEmpty ?? false
                ? product.description!
                : 'None',
          ),
          isThreeLine: (product.description?.length ?? 0) > 60,
          onTap: () async {
            final String? text = await promptForText(
              context,
              title: 'Description',
              label: 'Description',
              initial: product.description ?? '',
              helper: 'Shown when the drink is opened on the POS',
            );
            if (text == null || !context.mounted) return;
            await runMenuEdit(
              context,
              ref,
              () => repo.updateProduct(product.copyWith(description: text)),
              successMessage: 'Saved',
            );
          },
        ),
      ],
    );
  }
}

class _SizesSection extends ConsumerWidget {
  const _SizesSection({required this.data, required this.product});

  final ProductEditorData data;
  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MenuRepository repo = ref.watch(menuRepositoryProvider);
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            KuboSpacing.lg,
            0,
            KuboSpacing.lg,
            KuboSpacing.sm,
          ),
          child: Text(
            'Each size is priced on its own. The starred size is the one '
            'already selected when the drink is tapped.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        for (final DrinkSize size in data.allSizes)
          _SizeRow(
            size: size,
            productSize: product.sizes
                .where((ProductSize ps) => ps.size.id == size.id)
                .firstOrNull,
            onEdit: (ProductSize? current) async {
              final String? raw = await promptForText(
                context,
                title: '${product.name} · ${size.name}',
                label: 'Price in pesos',
                initial: current?.price.toPlainString() ?? '',
                helper: 'e.g. 139 or 139.50',
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              );
              if (raw == null || !context.mounted) return;
              final Money? price = Money.tryParse(raw);
              if (price == null || price.isNegative) {
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(
                    const SnackBar(
                      content: Text('Enter a price like 139 or 139.50'),
                    ),
                  );
                return;
              }
              await runMenuEdit(
                context,
                ref,
                () => repo.setProductSize(
                  productId: product.id,
                  sizeId: size.id,
                  priceCentavos: price.centavos,
                  isAvailable: current?.isAvailable ?? true,
                  isDefaultSize: current?.isDefaultSize ?? false,
                ),
                successMessage: '${size.name} set to ${price.format()}',
              );
            },
            onToggleAvailable: (ProductSize current, bool value) => runMenuEdit(
              context,
              ref,
              () => repo.setProductSize(
                productId: product.id,
                sizeId: size.id,
                priceCentavos: current.price.centavos,
                isAvailable: value,
                isDefaultSize: current.isDefaultSize,
              ),
            ),
            onMakeDefault: (ProductSize current) => runMenuEdit(
              context,
              ref,
              () => repo.setProductSize(
                productId: product.id,
                sizeId: size.id,
                priceCentavos: current.price.centavos,
                isAvailable: current.isAvailable,
                isDefaultSize: true,
              ),
              successMessage: '${size.name} is now the default size',
            ),
            onRemove: (ProductSize current) async {
              final bool ok = await confirm(
                context,
                title: 'Remove ${size.name}?',
                message:
                    '${product.name} will no longer be sold in ${size.name}.',
                confirmLabel: 'Remove',
                destructive: true,
              );
              if (!ok || !context.mounted) return;
              await runMenuEdit(
                context,
                ref,
                () => repo.removeProductSize(
                  productId: product.id,
                  sizeId: size.id,
                ),
                successMessage: '${size.name} removed',
              );
            },
          ),
      ],
    );
  }
}

class _SizeRow extends StatelessWidget {
  const _SizeRow({
    required this.size,
    required this.productSize,
    required this.onEdit,
    required this.onToggleAvailable,
    required this.onMakeDefault,
    required this.onRemove,
  });

  final DrinkSize size;
  final ProductSize? productSize;
  final void Function(ProductSize?) onEdit;
  final void Function(ProductSize, bool) onToggleAvailable;
  final void Function(ProductSize) onMakeDefault;
  final void Function(ProductSize) onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ProductSize? ps = productSize;

    if (ps == null) {
      return ListTile(
        leading: const Icon(Icons.add_circle_outline),
        title: Text('${size.name} · ${size.volumeLabel}'),
        subtitle: const Text('Not sold at this size'),
        onTap: () => onEdit(null),
      );
    }

    return ListTile(
      leading: IconButton(
        icon: Icon(
          ps.isDefaultSize ? Icons.star : Icons.star_border,
          color: ps.isDefaultSize ? theme.colorScheme.secondary : null,
        ),
        tooltip: ps.isDefaultSize
            ? 'Already the default size'
            : 'Make this the default size',
        onPressed: ps.isDefaultSize ? null : () => onMakeDefault(ps),
      ),
      title: Text('${size.name} · ${size.volumeLabel}'),
      subtitle: Text(
        ps.isAvailable ? ps.price.format() : '${ps.price.format()} · off sale',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Switch(
            value: ps.isAvailable,
            onChanged: (bool v) => onToggleAvailable(ps, v),
          ),
          PopupMenuButton<String>(
            onSelected: (String action) =>
                action == 'edit' ? onEdit(ps) : onRemove(ps),
            itemBuilder: (BuildContext context) =>
                const <PopupMenuEntry<String>>[
                  PopupMenuItem<String>(
                    value: 'edit',
                    child: Text('Change price'),
                  ),
                  PopupMenuItem<String>(
                    value: 'remove',
                    child: Text('Remove size'),
                  ),
                ],
          ),
        ],
      ),
      onTap: () => onEdit(ps),
    );
  }
}

class _GroupsSection extends ConsumerWidget {
  const _GroupsSection({required this.data, required this.product});

  final ProductEditorData data;
  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MenuRepository repo = ref.watch(menuRepositoryProvider);
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            KuboSpacing.lg,
            0,
            KuboSpacing.lg,
            KuboSpacing.sm,
          ),
          child: Text(
            'Off means the choice is not offered on this drink at all. '
            '"Ask every time" shows it as soon as the drink opens; otherwise '
            'it folds behind More options and its default still applies.',
            style: theme.textTheme.bodySmall,
          ),
        ),
        for (final CustomizationGroup group in data.allGroups)
          _GroupRow(
            group: group,
            rule: data.ruleFor(group.id),
            defaultOptionIds: data.defaultOptionIds,
            onAttach: (bool attached) => runMenuEdit(
              context,
              ref,
              () => attached
                  ? repo.setProductRule(
                      productId: product.id,
                      groupId: group.id,
                      isVisible: true,
                    )
                  : repo.removeProductRule(
                      productId: product.id,
                      groupId: group.id,
                    ),
            ),
            onSetProactive: (bool proactive) => runMenuEdit(
              context,
              ref,
              () => repo.setProductRule(
                productId: product.id,
                groupId: group.id,
                isVisible: proactive,
                isProactiveOverride: proactive,
              ),
            ),
            onSetDefault: (CustomizationOption option, bool value) =>
                runMenuEdit(
                  context,
                  ref,
                  () => value
                      ? repo.setDefaultOption(
                          productId: product.id,
                          optionId: option.id,
                        )
                      : repo.clearDefaultOption(
                          productId: product.id,
                          optionId: option.id,
                        ),
                ),
          ),
      ],
    );
  }
}

class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.group,
    required this.rule,
    required this.defaultOptionIds,
    required this.onAttach,
    required this.onSetProactive,
    required this.onSetDefault,
  });

  final CustomizationGroup group;
  final ProductCustomizationRule? rule;
  final Set<int> defaultOptionIds;
  final ValueChanged<bool> onAttach;
  final ValueChanged<bool> onSetProactive;
  final void Function(CustomizationOption, bool) onSetDefault;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool attached = rule != null;
    final bool proactive = rule?.proactiveFor(group) ?? group.isProactive;
    final List<CustomizationOption> active = group.activeOptions;
    final List<CustomizationOption> defaults = active
        .where((CustomizationOption o) => defaultOptionIds.contains(o.id))
        .toList();

    return ExpansionTile(
      leading: Icon(
        attached ? Icons.check_circle_outline : Icons.radio_button_unchecked,
        color: attached
            ? theme.colorScheme.secondary
            : theme.colorScheme.outline,
      ),
      title: Text(group.name),
      subtitle: Text(
        !attached
            ? 'Not offered on this drink'
            : proactive
            ? 'Asked every time'
            : defaults.isEmpty
            ? 'Only if the customer asks'
            : 'Only if the customer asks · '
                  'defaults to ${defaults.map((CustomizationOption o) => o.name).join(', ')}',
      ),
      children: <Widget>[
        SwitchListTile(
          value: attached,
          title: const Text('Offer this on this drink'),
          onChanged: onAttach,
        ),
        if (attached)
          SwitchListTile(
            value: proactive,
            title: const Text('Ask every time'),
            subtitle: const Text(
              'Off keeps the order fast — it hides behind More options',
            ),
            onChanged: onSetProactive,
          ),
        if (attached && active.isNotEmpty) ...<Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              KuboSpacing.lg,
              KuboSpacing.sm,
              KuboSpacing.lg,
              0,
            ),
            child: Text('PRE-SELECTED', style: theme.textTheme.labelSmall),
          ),
          for (final CustomizationOption option in active)
            CheckboxListTile(
              value: defaultOptionIds.contains(option.id),
              title: Text(option.name),
              subtitle: option.priceDelta.isZero
                  ? null
                  : Text('+${option.priceDelta.format()}'),
              onChanged: (bool? v) => onSetDefault(option, v ?? false),
            ),
        ],
        const SizedBox(height: KuboSpacing.sm),
      ],
    );
  }
}

class _AvailabilitySection extends ConsumerWidget {
  const _AvailabilitySection({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MenuRepository repo = ref.watch(menuRepositoryProvider);
    return Column(
      children: <Widget>[
        SwitchListTile(
          value: product.isActive && !product.isArchived,
          title: const Text('On the menu'),
          subtitle: const Text(
            'Turn off to hide it for today without losing it',
          ),
          onChanged: product.isArchived
              ? null
              : (bool value) => runMenuEdit(
                  context,
                  ref,
                  () => repo.updateProduct(product.copyWith(isActive: value)),
                ),
        ),
        ListTile(
          leading: Icon(
            product.isArchived
                ? Icons.unarchive_outlined
                : Icons.archive_outlined,
          ),
          title: Text(product.isArchived ? 'Restore drink' : 'Archive drink'),
          subtitle: Text(
            product.isArchived
                ? 'Put it back on the menu'
                : 'Retire it for good. Past orders keep their record — nothing '
                      'is ever deleted.',
          ),
          onTap: () async {
            final bool ok = await confirm(
              context,
              title: product.isArchived
                  ? 'Restore ${product.name}?'
                  : 'Archive ${product.name}?',
              message: product.isArchived
                  ? 'It will be available to put back on the menu.'
                  : 'It comes off the POS. Every order that included it stays '
                        'exactly as it was sold.',
              confirmLabel: product.isArchived ? 'Restore' : 'Archive',
              destructive: !product.isArchived,
            );
            if (!ok || !context.mounted) return;
            await runMenuEdit(
              context,
              ref,
              () => product.isArchived
                  ? repo.restoreProduct(product.id)
                  : repo.archiveProduct(product.id),
              successMessage: product.isArchived ? 'Restored' : 'Archived',
            );
          },
        ),
      ],
    );
  }
}
