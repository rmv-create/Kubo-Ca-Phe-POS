import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/quantity/quantity.dart';
import '../../../domain/entities/ingredient.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/money_text.dart';
import '../../../shared/widgets/section_header.dart';
import '../../menu/state/menu_actions.dart';
import '../state/stock_actions.dart';
import 'ingredients_screen.dart';

/// What is on the shelf, what changed it, and what needs reordering.
class InventoryScreen extends ConsumerWidget {
  const InventoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Ingredient>> alerts = ref.watch(stockAlertsProvider);
    final AsyncValue<List<Ingredient>> all = ref.watch(ingredientsProvider);
    final AsyncValue<List<InventoryMovement>> movements = ref.watch(
      movementsProvider,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Inventory'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.fact_check_outlined),
            tooltip: 'Count the stock',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const StockCountScreen(),
              ),
            ),
          ),
        ],
      ),
      body: AsyncView<List<Ingredient>>(
        value: all,
        onRetry: () => ref.invalidate(ingredientsProvider),
        builder: (BuildContext context, List<Ingredient> data) {
          final List<Ingredient> tracked = data
              .where((Ingredient i) => i.isInventoryTracked)
              .toList();
          if (tracked.isEmpty) {
            return const EmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'Nothing is being counted',
              message:
                  'Add ingredients and switch on counting for the ones '
                  'you want to keep track of.',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: KuboSpacing.xxxl),
            children: <Widget>[
              alerts.maybeWhen(
                orElse: () => const SizedBox.shrink(),
                data: (List<Ingredient> flagged) => flagged.isEmpty
                    ? const SizedBox.shrink()
                    : _AlertBlock(alerts: flagged),
              ),
              const SectionHeader('On hand'),
              for (final Ingredient i in tracked)
                ListTile(
                  leading: StockDot(status: i.status),
                  title: Text(i.name),
                  subtitle: Text(
                    '${i.onHand?.format() ?? '0'} · '
                    '${i.onHandInPurchaseUnits ?? '—'}',
                  ),
                  trailing: Text(
                    i.status.label,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              const SectionHeader('Recent movements'),
              movements.maybeWhen(
                orElse: () => const SizedBox.shrink(),
                data: (List<InventoryMovement> list) => Column(
                  children: <Widget>[
                    if (list.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(KuboSpacing.lg),
                        child: Text('Nothing has moved yet.'),
                      ),
                    for (final InventoryMovement m in list.take(40))
                      _MovementTile(movement: m),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AlertBlock extends StatelessWidget {
  const _AlertBlock({required this.alerts});

  final List<Ingredient> alerts;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool anyCritical = alerts.any(
      (Ingredient i) => i.status == StockStatus.critical,
    );

    return Container(
      margin: const EdgeInsets.all(KuboSpacing.lg),
      padding: const EdgeInsets.all(KuboSpacing.lg),
      decoration: BoxDecoration(
        color: anyCritical
            ? theme.colorScheme.errorContainer
            : theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(KuboRadius.md),
        border: Border(
          left: BorderSide(
            color: anyCritical
                ? theme.colorScheme.error
                : theme.colorScheme.secondary,
            width: 3,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('STOCK ALERTS', style: theme.textTheme.labelSmall),
          const SizedBox(height: KuboSpacing.sm),
          for (final Ingredient i in alerts)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: <Widget>[
                  StockDot(status: i.status),
                  const SizedBox(width: KuboSpacing.sm),
                  Expanded(
                    child: Text(
                      '${i.name} — ${i.onHandInPurchaseUnits ?? i.onHand?.format() ?? '0'}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  Text(
                    i.status.label.toUpperCase(),
                    style: theme.textTheme.labelSmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _MovementTile extends StatelessWidget {
  const _MovementTile({required this.movement});

  final InventoryMovement movement;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool out = movement.delta.isNegative;
    return ListTile(
      dense: true,
      leading: Icon(
        out ? Icons.arrow_downward : Icons.arrow_upward,
        size: 18,
        color: out ? theme.colorScheme.error : theme.colorScheme.tertiary,
      ),
      title: Text('${movement.ingredientName} · ${movement.type.label}'),
      subtitle: Text(
        '${movement.before.format()} → ${movement.after.format()}'
        '${movement.reason == null ? '' : ' · ${movement.reason}'}',
      ),
      trailing: Text(
        movement.delta.format(),
        style: theme.textTheme.titleSmall,
      ),
    );
  }
}

/// Count what is really there, see the difference, then decide.
class StockCountScreen extends ConsumerStatefulWidget {
  const StockCountScreen({super.key});

  @override
  ConsumerState<StockCountScreen> createState() => _StockCountScreenState();
}

class _StockCountScreenState extends ConsumerState<StockCountScreen> {
  final Map<int, Quantity> _counted = <int, Quantity>{};

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Ingredient>> all = ref.watch(ingredientsProvider);
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Stock count')),
      body: AsyncView<List<Ingredient>>(
        value: all,
        builder: (BuildContext context, List<Ingredient> data) {
          final List<Ingredient> tracked = data
              .where((Ingredient i) => i.isInventoryTracked)
              .toList();
          return ListView(
            padding: const EdgeInsets.only(bottom: 120),
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.all(KuboSpacing.lg),
                child: Text(
                  'Enter what is actually on the shelf. Nothing changes until '
                  'you apply the count, and every adjustment is recorded with '
                  'a reason.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              for (final Ingredient i in tracked)
                _CountRow(
                  ingredient: i,
                  counted: _counted[i.id],
                  onTap: () async {
                    final Quantity? q = await promptForQuantity(
                      context,
                      title: 'How much ${i.name} is there?',
                      unit: i.baseUnit,
                      initial: _counted[i.id] ?? i.onHand,
                      helper:
                          'The app expects '
                          '${i.onHand?.format() ?? '0'}',
                    );
                    if (q == null) return;
                    setState(() => _counted[i.id] = q);
                  },
                ),
            ],
          );
        },
      ),
      bottomNavigationBar: _counted.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(KuboSpacing.lg),
                child: SizedBox(
                  height: KuboTouch.payButton,
                  child: FilledButton(
                    onPressed: _review,
                    child: Text(
                      'REVIEW ${_counted.length} '
                      'COUNT${_counted.length == 1 ? '' : 'S'}',
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  Future<void> _review() async {
    final List<StockVariance> variances = await ref
        .read(inventoryRepositoryProvider)
        .expectedAgainst(_counted);
    if (!mounted) return;

    final List<StockVariance> differences = variances
        .where((StockVariance v) => !v.matches)
        .toList();

    final bool? apply = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(
          differences.isEmpty ? 'Everything matches' : 'Apply this count?',
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (differences.isEmpty)
                const Text('The shelf agrees with the app. Nothing to change.')
              else ...<Widget>[
                const Text('These will be adjusted:'),
                const SizedBox(height: KuboSpacing.sm),
                for (final StockVariance v in differences)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${v.ingredient.name}: expected ${v.expected.format()}, '
                      'counted ${v.actual.format()} '
                      '(${v.variance.isNegative ? '' : '+'}${v.variance.format()})',
                    ),
                  ),
              ],
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not yet'),
          ),
          if (differences.isNotEmpty)
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Apply'),
            ),
        ],
      ),
    );
    if (apply != true || !mounted) return;

    final NavigatorState navigator = Navigator.of(context);
    final bool ok = await runStockEdit(
      context,
      ref,
      () => ref
          .read(inventoryRepositoryProvider)
          .applyStockCount(counted: _counted),
      successMessage: 'Stock adjusted',
    );
    if (ok) navigator.pop();
  }
}

class _CountRow extends StatelessWidget {
  const _CountRow({
    required this.ingredient,
    required this.counted,
    required this.onTap,
  });

  final Ingredient ingredient;
  final Quantity? counted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Quantity expected =
        ingredient.onHand ?? Quantity.zero(ingredient.baseUnit);
    final Quantity? actual = counted;
    final Quantity? variance = actual == null ? null : actual - expected;

    return ListTile(
      title: Text(ingredient.name),
      subtitle: Text('Expected ${expected.format()}'),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Text(
            actual?.format() ?? 'Tap to count',
            style: theme.textTheme.titleSmall,
          ),
          if (variance != null && !variance.isZero)
            Text(
              '${variance.isNegative ? '' : '+'}${variance.format()}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
      onTap: onTap,
    );
  }
}

/// Record a spill, a mistake, or something that went off.
class WasteScreen extends ConsumerWidget {
  const WasteScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<WasteEntry>> waste = ref.watch(wasteProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Waste'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Record waste',
            onPressed: () => _record(context, ref),
          ),
        ],
      ),
      body: AsyncView<List<WasteEntry>>(
        value: waste,
        onRetry: () => ref.invalidate(wasteProvider),
        builder: (BuildContext context, List<WasteEntry> data) {
          if (data.isEmpty) {
            return EmptyState(
              icon: Icons.delete_outline,
              title: 'Nothing wasted',
              message:
                  'Recording waste keeps your stock honest and shows what '
                  'it is costing you.',
              action: FilledButton(
                onPressed: () => _record(context, ref),
                child: const Text('Record waste'),
              ),
            );
          }
          return ListView.separated(
            itemCount: data.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (BuildContext context, int index) {
              final WasteEntry w = data[index];
              return ListTile(
                title: Text('${w.ingredientName} · ${w.quantity.format()}'),
                subtitle: Text(
                  '${w.reason.label} · ${w.businessDate}'
                  '${w.notes == null || w.notes!.isEmpty ? '' : ' · ${w.notes}'}',
                ),
                trailing: MoneyText(w.value),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _record(BuildContext context, WidgetRef ref) async {
    final List<Ingredient> all = await ref
        .read(inventoryRepositoryProvider)
        .ingredients();
    if (all.isEmpty || !context.mounted) return;

    final Ingredient? ingredient = await showModalBottomSheet<Ingredient>(
      context: context,
      useSafeArea: true,
      builder: (BuildContext context) => ListView(
        children: <Widget>[
          const SectionHeader('What was wasted?'),
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
    );
    if (amount == null || !amount.isPositive || !context.mounted) return;

    final WasteReason? reason = await showDialog<WasteReason>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        title: const Text('What happened?'),
        children: <Widget>[
          for (final WasteReason r in WasteReason.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(r),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(r.label),
              ),
            ),
        ],
      ),
    );
    if (reason == null || !context.mounted) return;

    final String? notes = await promptForText(
      context,
      title: 'Anything to add?',
      label: 'Notes',
      helper: 'Optional',
      confirmLabel: 'Record',
    );
    if (!context.mounted) return;

    await runStockEdit(
      context,
      ref,
      () => ref
          .read(inventoryRepositoryProvider)
          .recordWaste(
            ingredientId: ingredient.id,
            quantity: amount,
            reason: reason,
            notes: notes,
          ),
      successMessage: 'Waste recorded and stock reduced',
    );
  }
}
