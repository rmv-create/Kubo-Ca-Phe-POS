import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/money/money.dart';
import '../../../core/money/unit_cost.dart';
import '../../../core/quantity/measurement_unit.dart';
import '../../../core/quantity/quantity.dart';
import '../../../domain/entities/ingredient.dart';
import '../../../domain/repositories/inventory_repository.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/section_header.dart';
import '../../menu/state/menu_actions.dart';
import '../state/stock_actions.dart';

/// Everything the shop buys, including cups and lids.
class IngredientsScreen extends ConsumerWidget {
  const IngredientsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Ingredient>> ingredients = ref.watch(
      ingredientsProvider,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ingredients'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add ingredient',
            onPressed: () => _add(context, ref),
          ),
        ],
      ),
      body: AsyncView<List<Ingredient>>(
        value: ingredients,
        onRetry: () => ref.invalidate(ingredientsProvider),
        builder: (BuildContext context, List<Ingredient> data) {
          if (data.isEmpty) {
            return EmptyState(
              icon: Icons.grass_outlined,
              title: 'Nothing here yet',
              message:
                  'Add coffee, milk, syrups — and cups, lids and straws too. '
                  'Recipes cost drinks from what you pay for these.',
              action: FilledButton(
                onPressed: () => _add(context, ref),
                child: const Text('Add the first one'),
              ),
            );
          }
          final Map<String, List<Ingredient>> byCategory =
              <String, List<Ingredient>>{};
          for (final Ingredient i in data) {
            byCategory
                .putIfAbsent(
                  i.category ?? 'Uncategorised',
                  () => <Ingredient>[],
                )
                .add(i);
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
            children: <Widget>[
              for (final MapEntry<String, List<Ingredient>> entry
                  in byCategory.entries) ...<Widget>[
                SectionHeader(entry.key),
                ...entry.value.map(
                  (Ingredient i) => _IngredientTile(ingredient: i),
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    final InventoryRepository repo = ref.read(inventoryRepositoryProvider);

    final String? name = await promptForText(
      context,
      title: 'New ingredient',
      label: 'Name',
      helper: 'Coffee beans, Oat milk, Grande cup…',
    );
    if (name == null || name.trim().isEmpty || !context.mounted) return;

    final BaseUnit? unit = await showDialog<BaseUnit>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: Text('How do you measure $name?'),
        children: <Widget>[
          for (final (BaseUnit u, String hint) in <(BaseUnit, String)>[
            (BaseUnit.gram, 'Anything you weigh — beans, matcha, sugar'),
            (BaseUnit.millilitre, 'Anything you pour — milk, syrup, water'),
            (BaseUnit.piece, 'Anything you count — cups, lids, eggs'),
          ])
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(u),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${u.label} (${u.code})'),
                subtitle: Text(hint),
              ),
            ),
        ],
      ),
    );
    if (unit == null || !context.mounted) return;

    final String? purchaseUnit = await promptForText(
      context,
      title: 'How do you buy it?',
      label: 'Unit you buy in',
      initial: unit == BaseUnit.piece
          ? 'pack'
          : (unit == BaseUnit.gram ? 'kg' : 'L'),
      helper: 'kg, L, carton, bottle, pack…',
    );
    if (purchaseUnit == null || !context.mounted) return;

    final Quantity? perUnit = await promptForQuantity(
      context,
      title: 'How much is in one $purchaseUnit?',
      unit: unit,
      helper: 'A 1 kg bag is 1000 g. A 50-pack of cups is 50 pcs.',
    );
    if (perUnit == null || !perUnit.isPositive || !context.mounted) return;

    await runStockEdit(
      context,
      ref,
      () => repo.createIngredient(
        name: name,
        baseUnit: unit,
        purchaseUnitCode: purchaseUnit.trim().toLowerCase(),
        purchaseUnitLabel: purchaseUnit.trim(),
        purchaseUnitSize: perUnit,
      ),
      successMessage: '$name added — set its price next',
    );
  }
}

class _IngredientTile extends ConsumerWidget {
  const _IngredientTile({required this.ingredient});

  final Ingredient ingredient;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final Money? price = ingredient.purchasePrice;

    return ListTile(
      leading: StockDot(status: ingredient.status),
      title: Text(ingredient.name),
      subtitle: Text(
        <String>[
          if (ingredient.isInventoryTracked)
            ingredient.onHandInPurchaseUnits ?? '—'
          else
            'Not counted',
          price == null
              ? 'No price yet'
              : '${price.format()} / ${ingredient.purchaseUnitLabel}',
        ].join(' · '),
        style: price == null
            ? theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              )
            : null,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              IngredientEditorScreen(ingredientId: ingredient.id),
        ),
      ),
    );
  }
}

/// A dot plus a word — never colour alone.
class StockDot extends StatelessWidget {
  const StockDot({required this.status, super.key});

  final StockStatus status;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final (IconData icon, Color color) = switch (status) {
      StockStatus.critical => (Icons.error, theme.colorScheme.error),
      StockStatus.low => (Icons.warning_amber, theme.colorScheme.secondary),
      StockStatus.ok => (Icons.check_circle_outline, theme.colorScheme.outline),
      StockStatus.untracked => (
        Icons.remove_circle_outline,
        theme.colorScheme.outline,
      ),
    };
    return Tooltip(
      message: status.label,
      child: Icon(icon, color: color),
    );
  }
}

class IngredientEditorScreen extends ConsumerWidget {
  const IngredientEditorScreen({required this.ingredientId, super.key});

  final int ingredientId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Ingredient>> all = ref.watch(ingredientsProvider);

    return AsyncView<List<Ingredient>>(
      value: all,
      builder: (BuildContext context, List<Ingredient> data) {
        final Ingredient? ingredient = data
            .where((Ingredient i) => i.id == ingredientId)
            .firstOrNull;
        if (ingredient == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(
              icon: Icons.search_off,
              title: 'Not found',
              message: 'This ingredient may have been removed.',
            ),
          );
        }

        final InventoryRepository repo = ref.watch(inventoryRepositoryProvider);
        final ThemeData theme = Theme.of(context);

        return Scaffold(
          appBar: AppBar(title: Text(ingredient.name)),
          body: ListView(
            padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
            children: <Widget>[
              const SectionHeader('Cost'),
              ListTile(
                leading: const Icon(Icons.sell_outlined),
                title: Text('Price per ${ingredient.purchaseUnitLabel}'),
                subtitle: Text(
                  ingredient.purchasePrice?.format() ??
                      'Not set — drinks using this cannot be costed',
                  style: ingredient.purchasePrice == null
                      ? theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.error,
                        )
                      : null,
                ),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () async {
                  final Money? price = await promptForMoney(
                    context,
                    title: ingredient.name,
                    label: 'What one ${ingredient.purchaseUnitLabel} costs',
                    initial: ingredient.purchasePrice,
                    helper:
                        'The old price is kept, so past orders keep '
                        'their cost',
                  );
                  if (price == null || !context.mounted) return;
                  await runStockEdit(
                    context,
                    ref,
                    () => repo.recordCost(
                      ingredientId: ingredient.id,
                      cost: UnitCost.perPurchaseUnit(
                        price: price,
                        baseUnitsPerPurchaseUnit:
                            ingredient.purchaseUnitSize.inBaseUnits,
                        unit: ingredient.baseUnit,
                      ),
                    ),
                    successMessage: 'Price recorded',
                  );
                },
              ),
              _CostHistoryTile(ingredient: ingredient),
              const SectionHeader('Stock'),
              SwitchListTile(
                value: ingredient.isInventoryTracked,
                title: const Text('Count this'),
                subtitle: const Text(
                  'Turn off for anything made fresh daily, like ice. It is '
                  'still costed, just not counted down.',
                ),
                onChanged: (bool v) => runStockEdit(
                  context,
                  ref,
                  () => repo.updateIngredient(
                    ingredient.copyWith(isInventoryTracked: v),
                  ),
                ),
              ),
              if (ingredient.isInventoryTracked) ...<Widget>[
                ListTile(
                  leading: const Icon(Icons.inventory_2_outlined),
                  title: const Text('On hand'),
                  subtitle: Text(
                    '${ingredient.onHand?.format() ?? '0'} · '
                    '${ingredient.onHandInPurchaseUnits ?? '—'}',
                  ),
                ),
                _ThresholdTile(
                  ingredient: ingredient,
                  label: 'Reorder when below',
                  value: ingredient.reorderThreshold,
                  onChanged: (Quantity q) => repo.updateIngredient(
                    ingredient.copyWith(reorderThreshold: q),
                  ),
                ),
                _ThresholdTile(
                  ingredient: ingredient,
                  label: 'Critical when below',
                  value: ingredient.criticalThreshold,
                  onChanged: (Quantity q) => repo.updateIngredient(
                    ingredient.copyWith(criticalThreshold: q),
                  ),
                ),
              ],
              const SectionHeader('Details'),
              ListTile(
                leading: const Icon(Icons.straighten),
                title: const Text('Bought by the'),
                subtitle: Text(
                  '${ingredient.purchaseUnitLabel} · '
                  '${ingredient.purchaseUnitSize.format()} each',
                ),
              ),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('Category'),
                subtitle: Text(ingredient.category ?? 'Uncategorised'),
                onTap: () async {
                  final String? category = await promptForText(
                    context,
                    title: 'Category',
                    label: 'Category',
                    initial: ingredient.category ?? '',
                    helper: 'Coffee, Milk, Syrup, Packaging…',
                  );
                  if (category == null || !context.mounted) return;
                  await runStockEdit(
                    context,
                    ref,
                    () => repo.updateIngredient(
                      ingredient.copyWith(category: category),
                    ),
                    successMessage: 'Saved',
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ThresholdTile extends ConsumerWidget {
  const _ThresholdTile({
    required this.ingredient,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final Ingredient ingredient;
  final String label;
  final Quantity value;
  final Future<void> Function(Quantity) onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
    leading: const Icon(Icons.notifications_outlined),
    title: Text(label),
    subtitle: Text(value.isZero ? 'Not set' : value.format()),
    trailing: const Icon(Icons.edit_outlined),
    onTap: () async {
      final Quantity? q = await promptForQuantity(
        context,
        title: label,
        unit: ingredient.baseUnit,
        initial: value,
        helper: 'In ${ingredient.baseUnit.code}. Zero switches it off.',
      );
      if (q == null || !context.mounted) return;
      await runStockEdit(
        context,
        ref,
        () => onChanged(q),
        successMessage: 'Saved',
      );
    },
  );
}

class _CostHistoryTile extends ConsumerWidget {
  const _CostHistoryTile({required this.ingredient});

  final Ingredient ingredient;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
    leading: const Icon(Icons.history),
    title: const Text('Price history'),
    subtitle: const Text('Every price paid, so old orders keep old costs'),
    trailing: const Icon(Icons.chevron_right),
    onTap: () async {
      final List<IngredientCost> history = await ref
          .read(inventoryRepositoryProvider)
          .costHistory(ingredient.id);
      if (!context.mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        builder: (BuildContext context) => ListView(
          padding: const EdgeInsets.only(bottom: KuboSpacing.xl),
          children: <Widget>[
            const SectionHeader('Price history'),
            if (history.isEmpty)
              const Padding(
                padding: EdgeInsets.all(KuboSpacing.lg),
                child: Text('No price recorded yet.'),
              ),
            for (final IngredientCost c in history)
              ListTile(
                title: Text(
                  moneyFromMicroCentavos(
                    c.cost.costMicroCentavos(ingredient.purchaseUnitSize),
                  ).format(),
                ),
                subtitle: Text(
                  'per ${ingredient.purchaseUnitLabel} · '
                  'from ${c.effectiveFrom.toLocal().toString().substring(0, 16)} · '
                  '${c.source}',
                ),
              ),
          ],
        ),
      );
    },
  );
}
