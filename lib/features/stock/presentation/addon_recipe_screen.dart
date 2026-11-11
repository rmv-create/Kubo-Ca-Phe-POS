import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/money/money.dart';
import '../../../core/quantity/quantity.dart';
import '../../../domain/entities/ingredient.dart';
import '../../../domain/entities/menu.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/money_text.dart';
import '../../../shared/widgets/section_header.dart';
import '../state/stock_actions.dart';

/// What a customisation is made of.
///
/// Sea Salt Cold Foam is 20 g of cream, 30 g of fresh milk, 10 g of
/// condensed and 0.6 g of salt. Those amounts were in the app from the
/// start and nothing ever showed them, so she could not check one against
/// what she actually pours, or change one when she changes the recipe.
///
/// It reads like the drink recipes on purpose: the same lines, the same
/// amounts, the same cost at the bottom. An add-on is a small recipe.
class AddonRecipeScreen extends ConsumerWidget {
  const AddonRecipeScreen({
    required this.optionId,
    required this.optionName,
    required this.groupName,
    super.key,
  });

  final int optionId;
  final String optionName;
  final String groupName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<OptionEffect>> effects = ref.watch(
      optionEffectsProvider(optionId),
    );
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(optionName),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(
              left: KuboSpacing.lg,
              bottom: KuboSpacing.sm,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(groupName, style: theme.textTheme.labelSmall),
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addLine(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Add an ingredient'),
      ),
      body: AsyncView<List<OptionEffect>>(
        value: effects,
        onRetry: () => ref.invalidate(optionEffectsProvider(optionId)),
        builder: (BuildContext context, List<OptionEffect> lines) {
          if (lines.isEmpty) {
            return const EmptyState(
              icon: Icons.science_outlined,
              title: 'Takes nothing out of stock',
              message:
                  'This customisation costs nothing to make. Add an '
                  'ingredient if it should.',
            );
          }

          final Money total = lines.fold(
            Money.zero,
            (Money sum, OptionEffect l) => sum + (l.cost ?? Money.zero),
          );
          final bool anyUnpriced = lines.any(
            (OptionEffect l) => l.cost == null,
          );

          return ListView(
            padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
            children: <Widget>[
              const SectionHeader('What it takes'),
              for (final OptionEffect line in lines)
                _EffectTile(
                  line: line,
                  onEdit: () => _editLine(context, ref, line),
                  onRemove: () => _removeLine(context, ref, line),
                ),
              const Divider(height: 1),
              ListTile(
                title: const Text('Costs her'),
                subtitle: Text(
                  anyUnpriced
                      ? 'Some ingredients have no price yet'
                      : 'At today’s prices',
                ),
                trailing: MoneyText(total, emphasised: true),
              ),
              Padding(
                padding: const EdgeInsets.all(KuboSpacing.lg),
                child: Text(
                  'A minus takes something out of the drink rather than '
                  'adding to it — oat milk replaces the dairy instead '
                  'of going in beside it.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _addLine(BuildContext context, WidgetRef ref) async {
    final List<Ingredient> all = await ref
        .read(inventoryRepositoryProvider)
        .ingredients();
    if (all.isEmpty || !context.mounted) return;

    final Ingredient? ingredient = await showModalBottomSheet<Ingredient>(
      context: context,
      useSafeArea: true,
      builder: (BuildContext context) => ListView(
        children: <Widget>[
          const SectionHeader('Which ingredient?'),
          for (final Ingredient i in all)
            ListTile(
              title: Text(i.name),
              subtitle: Text(i.onHand?.format() ?? '—'),
              onTap: () => Navigator.of(context).pop(i),
            ),
        ],
      ),
    );
    if (ingredient == null || !context.mounted) return;

    final Quantity? amount = await promptForQuantity(
      context,
      title: 'How much ${ingredient.name}?',
      unit: ingredient.baseUnit,
      helper: 'A minus takes it out of the drink instead of adding it',
    );
    if (amount == null || !context.mounted) return;

    await _save(
      context,
      ref,
      () => ref
          .read(recipeRepositoryProvider)
          .saveEffect(
            optionId: optionId,
            ingredientId: ingredient.id,
            delta: amount,
          ),
    );
  }

  Future<void> _editLine(
    BuildContext context,
    WidgetRef ref,
    OptionEffect line,
  ) async {
    final Quantity? amount = await promptForQuantity(
      context,
      title: line.ingredientName,
      unit: line.delta.unit,
      initial: line.delta,
      helper: line.isForEveryDrink
          ? 'On every drink. Zero removes it.'
          : 'On ${line.where} only. Zero removes it.',
    );
    if (amount == null || !context.mounted) return;

    await _save(
      context,
      ref,
      () => ref
          .read(recipeRepositoryProvider)
          .saveEffect(
            optionId: optionId,
            ingredientId: line.ingredientId,
            delta: amount,
            productId: line.productId,
            sizeId: line.sizeId,
          ),
    );
  }

  Future<void> _removeLine(
    BuildContext context,
    WidgetRef ref,
    OptionEffect line,
  ) async {
    await _save(
      context,
      ref,
      () => ref
          .read(recipeRepositoryProvider)
          .removeEffect(
            optionId: optionId,
            ingredientId: line.ingredientId,
            productId: line.productId,
            sizeId: line.sizeId,
          ),
    );
  }

  Future<void> _save(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() change,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await change();
      ref.read(menuRevisionProvider.notifier).bump();
      messenger
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(content: Text('Saved')));
    } on AppException catch (error) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}

class _EffectTile extends StatelessWidget {
  const _EffectTile({
    required this.line,
    required this.onEdit,
    required this.onRemove,
  });

  final OptionEffect line;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Money? cost = line.cost;

    return ListTile(
      leading: Icon(
        line.takesOut ? Icons.remove_circle_outline : Icons.add_circle_outline,
        color: line.takesOut ? theme.colorScheme.error : null,
      ),
      title: Text(line.ingredientName),
      subtitle: Text(
        line.isForEveryDrink
            ? line.delta.format()
            : '${line.delta.format()} · ${line.where}',
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (cost != null) MoneyText(cost),
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
