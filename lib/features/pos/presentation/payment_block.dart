import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/money/money.dart';
import '../../../domain/entities/business_settings.dart';
import '../../../domain/entities/order_draft.dart';
import '../../../domain/services/discount_engine.dart';
import '../../../shared/widgets/money_text.dart';
import '../../receipts/presentation/receipt_screen.dart';
import '../state/cart_controller.dart';
import 'discount_sheet.dart';
import 'order_pane.dart';

/// How long a note on an order may be.
///
/// An 80mm receipt is about 40 characters wide, so this is five full lines —
/// more than anything she has needed, and still a receipt rather than a
/// letter.
const int noteLimit = 200;

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
  @override
  Widget build(BuildContext context) {
    final OrderDraft draft = ref.watch(cartProvider);
    final BusinessSettings settings = ref.watch(settingsControllerProvider);
    final Money total = draft.totalWith(settings);

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
              child: _TotalRow(
                label: draft.isEmpty
                    ? 'No drinks yet'
                    : '${draft.drinkCount} '
                          'drink${draft.drinkCount == 1 ? '' : 's'} · view order',
                total: total,
              ),
            ),
          )
        else
          _TotalRow(
            label:
                '${draft.drinkCount} drink${draft.drinkCount == 1 ? '' : 's'}',
            total: total,
          ),

        if (!draft.isEmpty) ...<Widget>[
          const SizedBox(height: KuboSpacing.sm),

          // On a phone, paying waits behind one button.
          //
          // Everything it takes to settle an order — the discount and
          // delivery bar, five payment buttons, the not-paid-yet toggle and
          // COMPLETE ORDER — came to well over half the screen, and it was
          // on screen from the first drink onwards. While she is still
          // taking the order none of it is any use to her, and all of it is
          // in the way of the thing she is actually looking at, which is
          // the drinks.
          //
          // So it opens when she is ready to take the money, and until then
          // the bottom of the screen is the total and one button. The taps
          // to a finished sale do not change: CHARGE, then how they paid.
          //
          // On iPad the order pane has room for all of it at once, and a
          // sheet there would be ceremony for nothing.
          if (widget.showOrderButton)
            SizedBox(
              height: KuboTouch.primaryAction,
              child: FilledButton(
                onPressed: () => PaymentSheet.show(context),
                child: Text('CHARGE ${total.format()}'),
              ),
            )
          else
            const PaymentChoices(),
        ],
      ],
    );
  }
}

/// Everything it takes to settle an order: what is being taken off, how it
/// was paid, and the button that commits it.
///
/// Shown inline in the iPad order pane, and inside [PaymentSheet] on a phone.
class PaymentChoices extends ConsumerStatefulWidget {
  const PaymentChoices({this.onCompleted, super.key});

  /// Called once the sale is committed, so a sheet can close itself.
  final VoidCallback? onCompleted;

  @override
  ConsumerState<PaymentChoices> createState() => _PaymentChoicesState();
}

class _PaymentChoicesState extends ConsumerState<PaymentChoices> {
  bool _completing = false;

  @override
  Widget build(BuildContext context) {
    final OrderDraft draft = ref.watch(cartProvider);
    final BusinessSettings settings = ref.watch(settingsControllerProvider);
    final CartController cart = ref.read(cartProvider.notifier);

    final DiscountBreakdown discount = draft.discountWith(settings);
    final Money total = draft.totalWith(settings);
    final List<PaymentMethod> methods =
        ref.watch(paymentMethodsProvider).valueOrNull ?? PaymentMethod.builtIn;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // Only shown once there is something to take off, so the fast path
        // stays two taps.
        if (!discount.isEmpty || draft.deliveryFee.isPositive)
          _Adjustments(discount: discount, deliveryFee: draft.deliveryFee),

        const SizedBox(height: KuboSpacing.sm),
        _DiscountAndDeliveryBar(draft: draft, settings: settings),
        const SizedBox(height: KuboSpacing.md),

        if (draft.paymentMethod?.needsConfirmation ?? false)
          _PaymentConfirmation(draft: draft, total: total),

        _PayButtons(
          methods: methods,
          selected: draft.paymentMethod,
          enabled: true,
          onTap: (PaymentMethod method) => cart.setPaymentMethod(
            draft.paymentMethod == method ? null : method,
          ),
        ),
        const SizedBox(height: KuboSpacing.sm),
        _UnpaidToggle(draft: draft),
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
                : Text(
                    draft.whyNotComplete() ??
                        (draft.unpaid
                            ? 'COMPLETE · NOT PAID YET'
                            : 'COMPLETE ORDER'),
                  ),
          ),
        ),
      ],
    );
  }

  /// Commits, then returns to an empty order immediately — the confirmation is
  /// a toast she never has to dismiss, with the receipt one tap away.
  Future<void> _complete() async {
    setState(() => _completing = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final NavigatorState navigator = Navigator.of(context);
    try {
      final CompletedOrder order = await ref
          .read(orderServiceProvider)
          .complete(
            ref.read(cartProvider),
            settings: ref.read(settingsControllerProvider),
            takenByUserId: ref.read(signedInUserProvider)?.id,
          );
      ref.read(cartProvider.notifier).clear();
      ref.read(salesRevisionProvider.notifier).bump();
      widget.onCompleted?.call();
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            duration: const Duration(seconds: 4),
            content: Text(
              '${order.orderNo} · ${order.total.format()} · '
              '${order.paymentMethod?.label ?? 'awaiting payment'}',
            ),
            action: SnackBarAction(
              label: 'RECEIPT',
              onPressed: () => navigator.push(
                MaterialPageRoute<void>(
                  builder: (BuildContext context) =>
                      ReceiptScreen(orderId: order.id),
                ),
              ),
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

/// Taking the money, on a phone.
///
/// Closes itself the moment the sale is committed, and also if the order is
/// emptied underneath it — there is nothing to pay for then.
class PaymentSheet extends ConsumerWidget {
  const PaymentSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (BuildContext context) => const PaymentSheet(),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final OrderDraft draft = ref.watch(cartProvider);
    final ThemeData theme = Theme.of(context);
    final Money total = draft.totalWith(ref.watch(settingsControllerProvider));

    if (draft.isEmpty) {
      // The order was cleared from the review sheet behind this one.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).maybePop();
      });
      return const SizedBox.shrink();
    }

    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          KuboSpacing.lg,
          0,
          KuboSpacing.lg,
          KuboSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${draft.drinkCount} '
                    'drink${draft.drinkCount == 1 ? '' : 's'}',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                MoneyText(total, emphasised: true),
              ],
            ),
            const SizedBox(height: KuboSpacing.md),
            PaymentChoices(onCompleted: () => Navigator.of(context).maybePop()),
          ],
        ),
      ),
    );
  }
}

class _TotalRow extends StatelessWidget {
  const _TotalRow({required this.label, required this.total});

  final String label;
  final Money total;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        MoneyText(total, emphasised: true),
      ],
    );
  }
}

/// The lines between the drinks and the amount due. Shown only when there is
/// one, because an order with nothing taken off should say nothing about it.
class _Adjustments extends StatelessWidget {
  const _Adjustments({required this.discount, required this.deliveryFee});

  final DiscountBreakdown discount;
  final Money deliveryFee;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? style = theme.textTheme.bodySmall;

    Widget line(String label, Money amount) => Padding(
      padding: const EdgeInsets.only(top: KuboSpacing.xs),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(label, style: style)),
          Text(amount.format(), style: style),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        line('Subtotal', discount.grossSales),
        if (discount.vatRemoved.isPositive)
          line('VAT-exempt (12%)', -discount.vatRemoved),
        if (discount.discountAmount.isPositive)
          line(
            '${discount.kind!.label} '
            '(${(discount.rateBp / 100).toStringAsFixed(0)}%)',
            -discount.discountAmount,
          ),
        if (deliveryFee.isPositive) line('Delivery fee', deliveryFee),
      ],
    );
  }
}

/// The two things that change the amount due, kept to one quiet row so they
/// never slow down an ordinary sale.
class _DiscountAndDeliveryBar extends ConsumerWidget {
  const _DiscountAndDeliveryBar({required this.draft, required this.settings});

  final OrderDraft draft;
  final BusinessSettings settings;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CartController cart = ref.read(cartProvider.notifier);
    final DiscountKind? kind = draft.discountKind;

    return Row(
      children: <Widget>[
        // She gives no Senior Citizen or PWD discount at the moment, so the
        // button is not on the counter screen at all. The whole engine is
        // still there behind Settings → Receipt when she needs it.
        if (settings.discountsEnabled)
          Expanded(
            child: OutlinedButton.icon(
              onPressed: draft.isEmpty
                  ? null
                  : () => DiscountSheet.show(context),
              icon: Icon(kind == null ? Icons.percent : Icons.check, size: 18),
              label: Text(
                kind == null ? 'Discount' : kind.label,
                overflow: TextOverflow.ellipsis,
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(KuboTouch.chip),
              ),
            ),
          )
        else
          const Spacer(),
        const SizedBox(width: KuboSpacing.sm),
        SizedBox(
          width: KuboTouch.chip,
          height: KuboTouch.chip,
          child: OutlinedButton(
            onPressed: draft.isEmpty
                ? null
                : () => _askNote(context, cart, draft.note),
            style: OutlinedButton.styleFrom(
              padding: EdgeInsets.zero,
              foregroundColor: draft.note == null
                  ? null
                  : Theme.of(context).colorScheme.primary,
            ),
            child: Icon(
              draft.note == null
                  ? Icons.sticky_note_2_outlined
                  : Icons.sticky_note_2,
              size: 18,
            ),
          ),
        ),
        if (settings.deliveryFeeEnabled) ...<Widget>[
          const SizedBox(width: KuboSpacing.sm),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: draft.isEmpty
                  ? null
                  : () => _askDeliveryFee(context, cart, draft.deliveryFee),
              icon: const Icon(Icons.delivery_dining_outlined, size: 18),
              label: Text(
                draft.deliveryFee.isZero
                    ? 'Delivery'
                    : draft.deliveryFee.format(),
                overflow: TextOverflow.ellipsis,
              ),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(KuboTouch.chip),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// A note on this one order: "leave at the gate", "for Tita's birthday".
  /// It prints on the receipt and stays with the order.
  Future<void> _askNote(
    BuildContext context,
    CartController cart,
    String? current,
  ) async {
    final TextEditingController controller = TextEditingController(
      text: current ?? '',
    );
    final String? entered = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Note for this order'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          // Long enough for anything a customer actually asks for, short
          // enough that the receipt stays a receipt. The counter shows how
          // much is left rather than silently cutting her off.
          maxLength: noteLimit,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Leave at the gate · no straw · for pick-up at 3pm',
            helperText: 'Printed on the receipt',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(''),
            child: const Text('No note'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (entered != null) cart.setNote(entered);
  }

  Future<void> _askDeliveryFee(
    BuildContext context,
    CartController cart,
    Money current,
  ) async {
    final TextEditingController controller = TextEditingController(
      text: current.isZero ? '' : current.toPlainString(),
    );
    final Money? entered = await showDialog<Money>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Delivery fee'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(prefixText: '₱ '),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(Money.zero),
            child: const Text('No fee'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(
              context,
            ).pop(Money.tryParse(controller.text) ?? Money.zero),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (entered != null) cart.setDeliveryFee(entered);
  }
}

/// Finish the order now, take the money later.
///
/// An online order runs the other way round from the counter: the drinks are
/// rung up, the receipt goes out over Messenger, and the customer pays against
/// it. This is the one switch that lets the order be finished honestly in that
/// order, and the receipt then says NOT YET PAID on its face.
class _UnpaidToggle extends ConsumerWidget {
  const _UnpaidToggle({required this.draft});

  final OrderDraft draft;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final bool on = draft.unpaid;

    return SizedBox(
      height: KuboTouch.chip,
      child: OutlinedButton.icon(
        onPressed: draft.isEmpty
            ? null
            : () => ref.read(cartProvider.notifier).setUnpaid(!on),
        icon: Icon(
          on ? Icons.check_box : Icons.check_box_outline_blank,
          size: 18,
        ),
        label: const Text('Not paid yet — send the receipt first'),
        style: OutlinedButton.styleFrom(
          foregroundColor: on ? theme.colorScheme.primary : null,
          side: on ? BorderSide(color: theme.colorScheme.primary) : null,
        ),
      ),
    );
  }
}

class _PayButtons extends StatelessWidget {
  const _PayButtons({
    required this.methods,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final List<PaymentMethod> methods;
  final PaymentMethod? selected;
  final bool enabled;
  final void Function(PaymentMethod) onTap;

  @override
  Widget build(BuildContext context) {
    if (methods.isEmpty) {
      return Text(
        'No payment methods are switched on. Add one under Manage → Payment '
        'methods.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }

    // Two across reads well and keeps each button inside the thumb arc; more
    // than that and they wrap rather than shrink below a tappable size.
    return Wrap(
      spacing: KuboSpacing.sm,
      runSpacing: KuboSpacing.sm,
      children: <Widget>[
        for (final PaymentMethod method in methods)
          SizedBox(
            width: _widthFor(context, methods.length),
            child: _PayButton(
              method: method,
              isSelected: selected == method,
              onTap: enabled ? () => onTap(method) : null,
            ),
          ),
      ],
    );
  }

  double _widthFor(BuildContext context, int count) {
    final double available = MediaQuery.sizeOf(context).width - 64;
    final int perRow = count <= 2 ? count : 2;
    return (available - KuboSpacing.sm * (perRow - 1)) / perRow;
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
    // Cash is money in a tin; anything that has to be confirmed arrived
    // through a phone. Methods the owner adds herself take the phone icon,
    // which is true of every digital wallet in the Philippines.
    final IconData icon = method.takesTendered
        ? Icons.payments_outlined
        : Icons.smartphone_outlined;

    return SizedBox(
      height: KuboTouch.payButton,
      child: isSelected
          ? FilledButton.icon(
              onPressed: onTap,
              icon: Icon(icon),
              label: Text(
                method.label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            )
          : OutlinedButton.icon(
              onPressed: onTap,
              icon: Icon(icon),
              label: Text(
                method.label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.onSurface,
              ),
            ),
    );
  }
}

/// Money that lands somewhere the POS cannot see does not mark an order paid.
/// Choosing such a method only asks the owner to check; the order stays
/// incomplete until she says the money arrived.
class _PaymentConfirmation extends ConsumerStatefulWidget {
  const _PaymentConfirmation({required this.draft, required this.total});

  final OrderDraft draft;
  final Money total;

  @override
  ConsumerState<_PaymentConfirmation> createState() =>
      _PaymentConfirmationState();
}

class _PaymentConfirmationState extends ConsumerState<_PaymentConfirmation> {
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
    final bool confirmed = widget.draft.paymentConfirmed;
    final PaymentMethod method = widget.draft.paymentMethod!;

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
                '${widget.total.format()} received',
                style: theme.textTheme.titleSmall,
              ),
              subtitle: Text(
                confirmed
                    ? 'Confirmed. The order can be completed.'
                    : 'Check ${method.label} first. Nothing is recorded as '
                          'paid until you tick this.',
                style: theme.textTheme.bodySmall,
              ),
              onChanged: (bool? value) =>
                  cart.setPaymentConfirmed(value ?? false),
            ),
            if (method.takesReference)
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
                    decoration: InputDecoration(
                      labelText: '${method.label} reference',
                      helperText: 'Optional',
                    ),
                    onChanged: cart.setPaymentReference,
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
