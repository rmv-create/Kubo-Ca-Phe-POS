import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/money/money.dart';
import '../../../core/money/unit_cost.dart';
import '../../../core/quantity/quantity.dart';
import '../../../domain/entities/ingredient.dart';
import '../../../domain/entities/recipe.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/section_header.dart';
import '../state/stock_actions.dart';

/// One recipe per drink per size. Small and Grande are always separate.
class RecipesScreen extends ConsumerWidget {
  const RecipesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Recipe>> recipes = ref.watch(recipesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Recipes')),
      body: AsyncView<List<Recipe>>(
        value: recipes,
        onRetry: () => ref.invalidate(recipesProvider),
        builder: (BuildContext context, List<Recipe> data) {
          if (data.isEmpty) {
            return const EmptyState(
              icon: Icons.science_outlined,
              title: 'No drinks to write recipes for',
              message: 'Add drinks and sizes in Menu first.',
            );
          }
          final Map<String, List<Recipe>> byProduct = <String, List<Recipe>>{};
          for (final Recipe r in data) {
            byProduct.putIfAbsent(r.productName, () => <Recipe>[]).add(r);
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(KuboSpacing.lg),
                child: Text(
                  'Each size gets its own recipe — a Grande is never a Small '
                  'times two. Editing a recipe starts a new version, so orders '
                  'already sold keep the cost they were sold at.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              for (final MapEntry<String, List<Recipe>> entry
                  in byProduct.entries) ...<Widget>[
                SectionHeader(entry.key),
                ...entry.value.map((Recipe r) => _RecipeTile(recipe: r)),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _RecipeTile extends StatelessWidget {
  const _RecipeTile({required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final RecipeVersion? current = recipe.current;
    final Money? cost = current?.cost;

    final String subtitle;
    if (current == null || current.lines.isEmpty) {
      subtitle = 'No recipe yet — these sales cannot be costed';
    } else if (cost == null) {
      subtitle = 'No price for ${current.ingredientsWithoutCost.join(', ')}';
    } else {
      subtitle =
          '${current.lines.length} ingredients · '
          'costs ${cost.format()} · v${current.versionNo}';
    }

    return ListTile(
      leading: Icon(
        recipe.hasRecipe ? Icons.receipt_long : Icons.receipt_long_outlined,
        color: cost == null ? theme.colorScheme.error : null,
      ),
      title: Text('${recipe.sizeName} · ${recipe.sizeVolumeOz.round()} oz'),
      subtitle: Text(
        subtitle,
        style: cost == null
            ? theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              )
            : null,
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => RecipeEditorScreen(
            productId: recipe.productId,
            sizeId: recipe.sizeId,
          ),
        ),
      ),
    );
  }
}

class RecipeEditorScreen extends ConsumerStatefulWidget {
  const RecipeEditorScreen({
    required this.productId,
    required this.sizeId,
    super.key,
  });

  final int productId;
  final int sizeId;

  @override
  ConsumerState<RecipeEditorScreen> createState() => _RecipeEditorScreenState();
}

class _RecipeEditorScreenState extends ConsumerState<RecipeEditorScreen> {
  Map<int, Quantity>? _draft;
  bool _dirty = false;

  void _seed(Recipe recipe) {
    if (_draft != null) return;
    _draft = <int, Quantity>{
      for (final RecipeLine line in recipe.current?.lines ?? <RecipeLine>[])
        line.ingredientId: line.quantity,
    };
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Recipe>> recipes = ref.watch(recipesProvider);
    final AsyncValue<List<Ingredient>> ingredients = ref.watch(
      ingredientsProvider,
    );

    return AsyncView<List<Recipe>>(
      value: recipes,
      builder: (BuildContext context, List<Recipe> data) {
        final Recipe? recipe = data
            .where(
              (Recipe r) =>
                  r.productId == widget.productId && r.sizeId == widget.sizeId,
            )
            .firstOrNull;
        if (recipe == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const EmptyState(
              icon: Icons.search_off,
              title: 'Not found',
              message: 'This drink or size may have been removed.',
            ),
          );
        }
        _seed(recipe);

        return AsyncView<List<Ingredient>>(
          value: ingredients,
          builder: (BuildContext context, List<Ingredient> all) {
            final Map<int, Ingredient> byId = <int, Ingredient>{
              for (final Ingredient i in all) i.id: i,
            };
            final Map<int, Quantity> draft = _draft!;
            final Money? cost = _costOf(draft, byId);

            return Scaffold(
              appBar: AppBar(title: Text(recipe.title)),
              body: ListView(
                padding: const EdgeInsets.only(bottom: 140),
                children: <Widget>[
                  _CostBanner(recipe: recipe, draft: draft, byId: byId),
                  const SectionHeader('Goes into one drink'),
                  if (draft.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(KuboSpacing.lg),
                      child: Text(
                        all.isEmpty
                            ? 'Add ingredients first, in Management → '
                                  'Ingredients.'
                            : 'Nothing yet. Add what goes into a '
                                  '${recipe.title.toLowerCase()}.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  for (final MapEntry<int, Quantity> line in draft.entries)
                    _LineTile(
                      ingredient: byId[line.key],
                      quantity: line.value,
                      onEdit: () => _editLine(line.key, byId[line.key]),
                      onRemove: () => setState(() {
                        draft.remove(line.key);
                        _dirty = true;
                      }),
                    ),
                  Padding(
                    padding: const EdgeInsets.all(KuboSpacing.lg),
                    child: OutlinedButton.icon(
                      onPressed: all.isEmpty
                          ? null
                          : () => _addLine(all, draft),
                      icon: const Icon(Icons.add),
                      label: const Text('Add an ingredient'),
                    ),
                  ),
                  if (recipe.versions.length > 1)
                    _VersionHistory(recipe: recipe),
                ],
              ),
              bottomNavigationBar: _SaveBar(
                cost: cost,
                enabled: _dirty && draft.isNotEmpty,
                onSave: () => _save(recipe, draft),
              ),
            );
          },
        );
      },
    );
  }

  Money? _costOf(Map<int, Quantity> draft, Map<int, Ingredient> byId) {
    if (draft.isEmpty) return null;
    int micro = 0;
    for (final MapEntry<int, Quantity> line in draft.entries) {
      final Ingredient? ingredient = byId[line.key];
      if (ingredient?.currentCost == null) return null;
      micro += ingredient!.currentCost!.costMicroCentavos(line.value);
    }
    return moneyFromMicroCentavos(micro);
  }

  Future<void> _addLine(List<Ingredient> all, Map<int, Quantity> draft) async {
    final List<Ingredient> available = all
        .where((Ingredient i) => !draft.containsKey(i.id))
        .toList();
    if (available.isEmpty) return;

    final Ingredient? picked = await showModalBottomSheet<Ingredient>(
      context: context,
      useSafeArea: true,
      builder: (BuildContext context) => ListView(
        children: <Widget>[
          const SectionHeader('Add an ingredient'),
          for (final Ingredient i in available)
            ListTile(
              title: Text(i.name),
              subtitle: Text(
                i.currentCost == null
                    ? 'No price yet'
                    : '${i.purchasePrice?.format()} / ${i.purchaseUnitLabel}',
              ),
              onTap: () => Navigator.of(context).pop(i),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;

    final Quantity? amount = await promptForQuantity(
      context,
      title: 'How much ${picked.name}?',
      unit: picked.baseUnit,
      helper: 'For one drink',
    );
    if (amount == null || !amount.isPositive) return;
    setState(() {
      draft[picked.id] = amount;
      _dirty = true;
    });
  }

  Future<void> _editLine(int ingredientId, Ingredient? ingredient) async {
    if (ingredient == null) return;
    final Quantity? amount = await promptForQuantity(
      context,
      title: 'How much ${ingredient.name}?',
      unit: ingredient.baseUnit,
      initial: _draft![ingredientId],
      helper: 'For one drink',
    );
    if (amount == null || !amount.isPositive) return;
    setState(() {
      _draft![ingredientId] = amount;
      _dirty = true;
    });
  }

  Future<void> _save(Recipe recipe, Map<int, Quantity> draft) async {
    final bool ok = await runStockEdit(
      context,
      ref,
      () => ref
          .read(recipeRepositoryProvider)
          .saveVersion(
            productId: recipe.productId,
            sizeId: recipe.sizeId,
            lines: draft,
          ),
      successMessage: 'Recipe saved as a new version',
    );
    if (ok && mounted) setState(() => _dirty = false);
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({
    required this.ingredient,
    required this.quantity,
    required this.onEdit,
    required this.onRemove,
  });

  final Ingredient? ingredient;
  final Quantity quantity;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Money? cost = ingredient?.currentCost == null
        ? null
        : moneyFromMicroCentavos(
            ingredient!.currentCost!.costMicroCentavos(quantity),
          );

    return ListTile(
      title: Text(ingredient?.name ?? 'Removed ingredient'),
      subtitle: Text(
        cost == null ? 'No price yet' : cost.format(),
        style: cost == null
            ? theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              )
            : null,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(quantity.format(), style: theme.textTheme.titleSmall),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Remove',
            onPressed: onRemove,
          ),
        ],
      ),
      onTap: onEdit,
    );
  }
}

class _CostBanner extends StatelessWidget {
  const _CostBanner({
    required this.recipe,
    required this.draft,
    required this.byId,
  });

  final Recipe recipe;
  final Map<int, Quantity> draft;
  final Map<int, Ingredient> byId;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<String> missing = <String>[
      for (final int id in draft.keys)
        if (byId[id]?.currentCost == null) byId[id]?.name ?? 'Unknown',
    ];
    if (missing.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.all(KuboSpacing.lg),
      padding: const EdgeInsets.all(KuboSpacing.lg),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(KuboRadius.md),
        border: Border(
          left: BorderSide(color: theme.colorScheme.error, width: 3),
        ),
      ),
      child: Text(
        'This recipe cannot be costed until you set a price for '
        '${missing.join(', ')}. Sales will still record correctly; the profit '
        'figures just leave these out rather than guessing.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onErrorContainer,
        ),
      ),
    );
  }
}

class _VersionHistory extends StatelessWidget {
  const _VersionHistory({required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      const SectionHeader('Earlier versions'),
      for (final RecipeVersion v in recipe.versions.skip(1))
        ListTile(
          leading: const Icon(Icons.history),
          title: Text('Version ${v.versionNo}'),
          subtitle: Text(
            '${v.lines.length} ingredients · '
            'used from ${v.effectiveFrom.toLocal().toString().substring(0, 10)}'
            '${v.effectiveTo == null ? '' : ' to ${v.effectiveTo!.toLocal().toString().substring(0, 10)}'}',
          ),
        ),
    ],
  );
}

class _SaveBar extends StatelessWidget {
  const _SaveBar({
    required this.cost,
    required this.enabled,
    required this.onSave,
  });

  final Money? cost;
  final bool enabled;
  final VoidCallback onSave;

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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Costs to make',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  Text(
                    cost?.format() ?? 'not costable yet',
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: KuboSpacing.sm),
              SizedBox(
                height: KuboTouch.payButton,
                child: FilledButton(
                  onPressed: enabled ? onSave : null,
                  child: const Text('SAVE RECIPE'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
