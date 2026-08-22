import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../domain/entities/order_draft.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/money_text.dart';
import '../state/cart_controller.dart';
import 'product_config_sheet.dart';

/// The running order: what is in it, and every way to change it.
class OrderLines extends ConsumerWidget {
  const OrderLines({this.padding, super.key});

  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final OrderDraft draft = ref.watch(cartProvider);

    if (draft.isEmpty) {
      return const EmptyState(
        icon: Icons.local_cafe_outlined,
        title: 'No drinks yet',
        message: 'Tap a drink to start the order.',
      );
    }

    return ListView.separated(
      padding: padding ?? const EdgeInsets.symmetric(vertical: KuboSpacing.sm),
      itemCount: draft.items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) =>
          _OrderLine(item: draft.items[index]),
    );
  }
}

class _OrderLine extends ConsumerWidget {
  const _OrderLine({required this.item});

  final DraftItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final CartController cart = ref.read(cartProvider.notifier);
    final List<DraftOption> notable = item.notableOptions;

    return Dismissible(
      key: ValueKey<String>(item.lineId),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: KuboSpacing.lg),
        color: theme.colorScheme.errorContainer,
        child: Icon(
          Icons.delete_outline,
          color: theme.colorScheme.onErrorContainer,
        ),
      ),
      onDismissed: (_) => cart.removeItem(item.lineId),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          KuboSpacing.lg,
          KuboSpacing.md,
          KuboSpacing.sm,
          KuboSpacing.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    item.title.toUpperCase(),
                    style: theme.textTheme.titleSmall,
                  ),
                  if (notable.isNotEmpty)
                    Text(
                      notable.map((DraftOption o) => o.option.name).join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                  const SizedBox(height: KuboSpacing.sm),
                  Row(
                    children: <Widget>[
                      _StepperButton(
                        icon: Icons.remove,
                        tooltip: 'One fewer',
                        onPressed: () => cart.decrement(item.lineId),
                      ),
                      SizedBox(
                        width: 36,
                        child: Text(
                          '${item.quantity}',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.titleMedium,
                        ),
                      ),
                      _StepperButton(
                        icon: Icons.add,
                        tooltip: 'One more',
                        onPressed: () => cart.increment(item.lineId),
                      ),
                      const SizedBox(width: KuboSpacing.sm),
                      _StepperButton(
                        icon: Icons.copy_outlined,
                        tooltip: 'Same again as a separate drink',
                        onPressed: () => cart.duplicateItem(item.lineId),
                      ),
                      _StepperButton(
                        icon: Icons.edit_outlined,
                        tooltip: 'Change this drink',
                        onPressed: () => ProductConfigSheet.show(
                          context,
                          product: item.product,
                          editingLineId: item.lineId,
                          initialSize: item.size,
                          initialOptionIds: item.options
                              .map((DraftOption o) => o.option.id)
                              .toSet(),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                MoneyText(item.lineTotal),
                if (item.quantity > 1)
                  Text(
                    '${item.unitPrice.format()} each',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StepperButton extends StatelessWidget {
  const _StepperButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    icon: Icon(icon, size: 20),
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    onPressed: onPressed,
  );
}

/// The full-screen order review on iPhone. On iPad the same lines are always
/// visible in the right-hand pane, so this is never needed there.
class OrderReviewSheet extends ConsumerWidget {
  const OrderReviewSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (BuildContext context) => DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (BuildContext context, ScrollController controller) =>
          const OrderReviewSheet(),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final OrderDraft draft = ref.watch(cartProvider);
    final ThemeData theme = Theme.of(context);

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            KuboSpacing.lg,
            KuboSpacing.sm,
            KuboSpacing.lg,
            KuboSpacing.sm,
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text('CURRENT ORDER', style: theme.textTheme.labelSmall),
              ),
              if (!draft.isEmpty)
                TextButton(
                  onPressed: () async {
                    final NavigatorState navigator = Navigator.of(context);
                    final bool ok = await _confirmClear(context);
                    if (!ok) return;
                    ref.read(cartProvider.notifier).clear();
                    navigator.maybePop();
                  },
                  child: const Text('Clear order'),
                ),
            ],
          ),
        ),
        const Expanded(child: OrderLines()),
        Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            border: Border(top: BorderSide(color: theme.colorScheme.outline)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(KuboSpacing.lg),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '${draft.drinkCount} '
                      'drink${draft.drinkCount == 1 ? '' : 's'}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  MoneyText(
                    draft.totalWith(ref.watch(settingsControllerProvider)),
                    emphasised: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  static Future<bool> _confirmClear(BuildContext context) async {
    final bool? answer = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Clear this order?'),
        content: const Text('Every drink in it will be removed.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }
}
