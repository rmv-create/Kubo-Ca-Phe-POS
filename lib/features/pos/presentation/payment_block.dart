import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/errors/app_exception.dart';
import '../../../domain/entities/order_draft.dart';
import '../../../shared/widgets/money_text.dart';
import '../state/cart_controller.dart';
import 'order_pane.dart';

/// Total, payment method, and the button that commits the sale.
///
/// This block never scrolls away: on iPhone it is pinned to the bottom inside
/// the thumb arc, on iPad it sits at the foot of the order pane.
class PaymentBlock extends ConsumerStatefulWidget {
  const PaymentBlock({this.showOrderButton = true, super.key});

  /// iPhone shows a tap-through to the order review; iPad already has the
  /// lines on screen and does not need it.
  final bool showOrderButton;

  @override
  ConsumerState<PaymentBlock> createState() => _PaymentBlockState();
}

class _PaymentBlockState extends ConsumerState<PaymentBlock> {
  bool _completing = false;

  @override
  Widget build(BuildContext context) {
    final OrderDraft draft = ref.watch(cartProvider);
    final ThemeData theme = Theme.of(context);
    final CartController cart = ref.read(cartProvider.notifier);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (widget.showOrderButton)
          InkWell(
            onTap: draft.isEmpty ? null : () => OrderReviewSheet.show(context),
            borderRadius: BorderRadius.circular(KuboRadius.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: KuboSpacing.xs),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      draft.isEmpty
                          ? 'No drinks yet'
                          : '${draft.drinkCount} '
                                'drink${draft.drinkCount == 1 ? '' : 's'} · view order',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  MoneyText(draft.total, emphasised: true),
                ],
              ),
            ),
          )
        else
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${draft.drinkCount} '
                  'drink${draft.drinkCount == 1 ? '' : 's'}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              MoneyText(draft.total, emphasised: true),
            ],
          ),
        const SizedBox(height: KuboSpacing.md),
        if (draft.paymentMethod == PaymentMethod.gcash)
          _GcashConfirmation(draft: draft),
        Row(
          children: <Widget>[
            for (final PaymentMethod method
                in PaymentMethod.values) ...<Widget>[
              Expanded(
                child: _PayButton(
                  method: method,
                  isSelected: draft.paymentMethod == method,
                  onTap: draft.isEmpty
                      ? null
                      : () => cart.setPaymentMethod(
                          draft.paymentMethod == method ? null : method,
                        ),
                ),
              ),
              if (method != PaymentMethod.values.last)
                const SizedBox(width: KuboSpacing.sm),
            ],
          ],
        ),
        const SizedBox(height: KuboSpacing.sm),
        SizedBox(
          height: KuboTouch.primaryAction,
          child: FilledButton(
            onPressed: draft.canComplete && !_completing ? _complete : null,
            child: _completing
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : Text(draft.whyNotComplete() ?? 'COMPLETE ORDER'),
          ),
        ),
      ],
    );
  }

  /// Commits, then returns to an empty order immediately — the confirmation is
  /// a toast she never has to dismiss.
  Future<void> _complete() async {
    setState(() => _completing = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final CompletedOrder order = await ref
          .read(orderServiceProvider)
          .complete(
            ref.read(cartProvider),
            settings: ref.read(settingsControllerProvider),
          );
      ref.read(cartProvider.notifier).clear();
      ref.read(salesRevisionProvider.notifier).bump();
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 2),
            content: Text(
              '${order.orderNo} · ${order.total.format()} · '
              '${order.paymentMethod.label}',
            ),
          ),
        );
    } on AppException catch (error) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _completing = false);
    }
  }
}

class _PayButton extends StatelessWidget {
  const _PayButton({
    required this.method,
    required this.isSelected,
    required this.onTap,
  });

  final PaymentMethod method;
  final bool isSelected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final IconData icon = method == PaymentMethod.cash
        ? Icons.payments_outlined
        : Icons.smartphone_outlined;

    return SizedBox(
      height: KuboTouch.payButton,
      child: isSelected
          ? FilledButton.icon(
              onPressed: onTap,
              icon: Icon(icon),
              label: Text(method.label.toUpperCase()),
            )
          : OutlinedButton.icon(
              onPressed: onTap,
              icon: Icon(icon),
              label: Text(method.label.toUpperCase()),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.onSurface,
              ),
            ),
    );
  }
}

/// GCash money lands in an app the POS cannot see. Selecting GCash therefore
/// does nothing except ask the owner to check; the order stays incomplete
/// until she says the money arrived.
class _GcashConfirmation extends ConsumerStatefulWidget {
  const _GcashConfirmation({required this.draft});

  final OrderDraft draft;

  @override
  ConsumerState<_GcashConfirmation> createState() => _GcashConfirmationState();
}

class _GcashConfirmationState extends ConsumerState<_GcashConfirmation> {
  final TextEditingController _reference = TextEditingController();
  bool _showReference = false;

  @override
  void dispose() {
    _reference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final CartController cart = ref.read(cartProvider.notifier);
    final bool confirmed = widget.draft.gcashConfirmed;

    // The fill has to come from a Material rather than a decoration, or the
    // tile inside paints its ink splash behind this box and the tap looks
    // dead.
    return Container(
      margin: const EdgeInsets.only(bottom: KuboSpacing.sm),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(KuboRadius.md),
        border: Border.all(
          color: confirmed
              ? theme.colorScheme.primary
              : theme.colorScheme.error,
          width: 2,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: confirmed
            ? theme.colorScheme.secondaryContainer
            : theme.colorScheme.errorContainer,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CheckboxListTile(
              value: confirmed,
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: KuboSpacing.md,
              ),
              title: Text(
                '${widget.draft.total.format()} received',
                style: theme.textTheme.titleSmall,
              ),
              subtitle: Text(
                confirmed
                    ? 'Confirmed. The order can be completed.'
                    : 'Check GCash first. Nothing is recorded as paid until you '
                          'tick this.',
                style: theme.textTheme.bodySmall,
              ),
              onChanged: (bool? value) =>
                  cart.setGcashConfirmed(value ?? false),
            ),
            if (!_showReference)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() => _showReference = true),
                  child: const Text('Add reference number'),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  KuboSpacing.md,
                  0,
                  KuboSpacing.md,
                  KuboSpacing.md,
                ),
                child: TextField(
                  controller: _reference,
                  decoration: const InputDecoration(
                    labelText: 'GCash reference',
                    helperText: 'Optional',
                  ),
                  onChanged: cart.setGcashReference,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
