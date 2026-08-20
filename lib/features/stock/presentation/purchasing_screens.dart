import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/money/money.dart';
import '../../../domain/entities/ingredient.dart';
import '../../../domain/entities/purchasing.dart';
import '../../../domain/repositories/purchasing_repository.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/money_text.dart';
import '../../../shared/widgets/section_header.dart';
import '../../menu/state/menu_actions.dart';
import '../state/stock_actions.dart';

class SuppliersScreen extends ConsumerWidget {
  const SuppliersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Supplier>> suppliers = ref.watch(suppliersProvider);
    final PurchasingRepository repo = ref.watch(purchasingRepositoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Suppliers'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add supplier',
            onPressed: () async {
              final String? name = await promptForText(
                context,
                title: 'New supplier',
                label: 'Name',
              );
              if (name == null || name.trim().isEmpty || !context.mounted) {
                return;
              }
              final String? contact = await promptForText(
                context,
                title: 'How do you reach them?',
                label: 'Phone, Viber or page',
                helper: 'Optional',
                confirmLabel: 'Add',
              );
              if (!context.mounted) return;
              await runStockEdit(
                context,
                ref,
                () => repo.createSupplier(name: name, contactDetails: contact),
                successMessage: 'Supplier added',
              );
            },
          ),
        ],
      ),
      body: AsyncView<List<Supplier>>(
        value: suppliers,
        onRetry: () => ref.invalidate(suppliersProvider),
        builder: (BuildContext context, List<Supplier> data) => data.isEmpty
            ? const EmptyState(
                icon: Icons.local_shipping_outlined,
                title: 'No suppliers yet',
                message: 'Add whoever you buy your beans and milk from.',
              )
            : ListView.separated(
                itemCount: data.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (BuildContext context, int index) {
                  final Supplier s = data[index];
                  return ListTile(
                    leading: const Icon(Icons.storefront_outlined),
                    title: Text(s.name),
                    subtitle: Text(
                      <String>[
                        if (s.contactPerson != null) s.contactPerson!,
                        if (s.contactDetails != null) s.contactDetails!,
                        '${s.ingredientCount} ingredient'
                            '${s.ingredientCount == 1 ? '' : 's'}',
                      ].join(' · '),
                    ),
                    onTap: () async {
                      final String? contact = await promptForText(
                        context,
                        title: s.name,
                        label: 'Phone, Viber or page',
                        initial: s.contactDetails ?? '',
                      );
                      if (contact == null || !context.mounted) return;
                      await runStockEdit(
                        context,
                        ref,
                        () => repo.updateSupplier(
                          s.copyWith(contactDetails: contact),
                        ),
                        successMessage: 'Saved',
                      );
                    },
                  );
                },
              ),
      ),
    );
  }
}

/// Record what came in. Stock goes up, and the price becomes the cost that
/// future drinks are costed at.
class PurchasesScreen extends ConsumerWidget {
  const PurchasesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Purchase>> purchases = ref.watch(purchasesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Purchases'),
        actions: <Widget>[
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Record a delivery',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => const RecordPurchaseScreen(),
              ),
            ),
          ),
        ],
      ),
      body: AsyncView<List<Purchase>>(
        value: purchases,
        onRetry: () => ref.invalidate(purchasesProvider),
        builder: (BuildContext context, List<Purchase> data) => data.isEmpty
            ? EmptyState(
                icon: Icons.shopping_basket_outlined,
                title: 'Nothing recorded yet',
                message:
                    'Recording a delivery adds the stock and updates what '
                    'your drinks cost to make.',
                action: FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) =>
                          const RecordPurchaseScreen(),
                    ),
                  ),
                  child: const Text('Record a delivery'),
                ),
              )
            : ListView.separated(
                itemCount: data.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (BuildContext context, int index) {
                  final Purchase p = data[index];
                  return ExpansionTile(
                    leading: const Icon(Icons.inventory_outlined),
                    title: Text(p.supplierName ?? 'No supplier'),
                    subtitle: Text(
                      '${p.businessDate} · ${p.lines.length} item'
                      '${p.lines.length == 1 ? '' : 's'}',
                    ),
                    trailing: MoneyText(p.total),
                    children: <Widget>[
                      for (final PurchaseLine line in p.lines)
                        ListTile(
                          dense: true,
                          title: Text(line.ingredientName),
                          subtitle: Text(line.quantity.format()),
                          trailing: MoneyText(line.totalCost),
                        ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

class RecordPurchaseScreen extends ConsumerStatefulWidget {
  const RecordPurchaseScreen({super.key});

  @override
  ConsumerState<RecordPurchaseScreen> createState() =>
      _RecordPurchaseScreenState();
}

class _RecordPurchaseScreenState extends ConsumerState<RecordPurchaseScreen> {
  final List<_DraftLine> _lines = <_DraftLine>[];
  Supplier? _supplier;

  Money get _total =>
      Money(_lines.fold(0, (int sum, _DraftLine l) => sum + l.cost.centavos));

  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<Supplier>> suppliers = ref.watch(suppliersProvider);
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Record a delivery')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 140),
        children: <Widget>[
          suppliers.maybeWhen(
            orElse: () => const SizedBox.shrink(),
            data: (List<Supplier> list) => ListTile(
              leading: const Icon(Icons.storefront_outlined),
              title: const Text('Supplier'),
              subtitle: Text(_supplier?.name ?? 'Not set — optional'),
              trailing: const Icon(Icons.chevron_right),
              onTap: list.isEmpty
                  ? null
                  : () async {
                      final Supplier? picked =
                          await showModalBottomSheet<Supplier>(
                            context: context,
                            useSafeArea: true,
                            builder: (BuildContext context) => ListView(
                              children: <Widget>[
                                const SectionHeader('Who delivered?'),
                                for (final Supplier s in list)
                                  ListTile(
                                    title: Text(s.name),
                                    onTap: () => Navigator.of(context).pop(s),
                                  ),
                              ],
                            ),
                          );
                      if (picked != null) setState(() => _supplier = picked);
                    },
            ),
          ),
          const SectionHeader('What came in'),
          for (final _DraftLine line in _lines)
            ListTile(
              title: Text(line.ingredient.name),
              subtitle: Text(
                '${line.quantity} ${line.ingredient.purchaseUnitLabel}'
                '${line.quantity == 1 ? '' : 's'}',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  MoneyText(line.cost),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Remove',
                    onPressed: () => setState(() => _lines.remove(line)),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(KuboSpacing.lg),
            child: OutlinedButton.icon(
              onPressed: _addLine,
              icon: const Icon(Icons.add),
              label: const Text('Add something'),
            ),
          ),
          if (_lines.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.lg),
              child: Text(
                'Recording this puts the stock in and makes these the prices '
                'your drinks are costed at from now on. Earlier orders keep '
                'the cost they were sold at.',
                style: theme.textTheme.bodySmall,
              ),
            ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(KuboSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text('Total', style: theme.textTheme.bodyMedium),
                  ),
                  MoneyText(_total, emphasised: true),
                ],
              ),
              const SizedBox(height: KuboSpacing.sm),
              SizedBox(
                height: KuboTouch.payButton,
                child: FilledButton(
                  onPressed: _lines.isEmpty ? null : _save,
                  child: const Text('RECORD DELIVERY'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _addLine() async {
    final List<Ingredient> all = await ref
        .read(inventoryRepositoryProvider)
        .ingredients();
    if (all.isEmpty || !mounted) return;

    final Ingredient? ingredient = await showModalBottomSheet<Ingredient>(
      context: context,
      useSafeArea: true,
      builder: (BuildContext context) => ListView(
        children: <Widget>[
          const SectionHeader('What came in?'),
          for (final Ingredient i in all)
            ListTile(
              title: Text(i.name),
              subtitle: Text('Bought by the ${i.purchaseUnitLabel}'),
              onTap: () => Navigator.of(context).pop(i),
            ),
        ],
      ),
    );
    if (ingredient == null || !mounted) return;

    final String? amountText = await promptForText(
      context,
      title: 'How many ${ingredient.purchaseUnitLabel}s?',
      label: ingredient.purchaseUnitLabel,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      helper:
          'One ${ingredient.purchaseUnitLabel} is '
          '${ingredient.purchaseUnitSize.format()}',
    );
    final double? amount = double.tryParse(amountText?.trim() ?? '');
    if (amount == null || amount <= 0 || !mounted) return;

    final Money? cost = await promptForMoney(
      context,
      title: 'What did that cost?',
      label: 'Total paid',
      helper: 'For all $amount ${ingredient.purchaseUnitLabel}s together',
    );
    if (cost == null || !mounted) return;

    setState(() {
      _lines.add(
        _DraftLine(ingredient: ingredient, quantity: amount, cost: cost),
      );
    });
  }

  Future<void> _save() async {
    final NavigatorState navigator = Navigator.of(context);
    final bool ok = await runStockEdit(
      context,
      ref,
      () => ref
          .read(purchasingRepositoryProvider)
          .recordPurchase(
            supplierId: _supplier?.id,
            lines: _lines
                .map(
                  (_DraftLine l) => PurchaseDraftLine(
                    ingredientId: l.ingredient.id,
                    quantityInPurchaseUnits: l.quantity,
                    totalCost: l.cost,
                  ),
                )
                .toList(),
          ),
      successMessage: 'Delivery recorded and stock updated',
    );
    if (ok) navigator.pop();
  }
}

class _DraftLine {
  const _DraftLine({
    required this.ingredient,
    required this.quantity,
    required this.cost,
  });

  final Ingredient ingredient;
  final double quantity;
  final Money cost;
}
