import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/money/money.dart';
import '../../../domain/entities/business_settings.dart';
import '../../../domain/entities/order_draft.dart';
import '../../../domain/services/discount_engine.dart';
import '../state/cart_controller.dart';

/// Takes something off the whole order.
///
/// Two different things live here. A **statutory** discount — Senior Citizen
/// or PWD — is set by law: she picks who is in front of her and never types
/// an amount, because a rate she could edit would not be a statutory rate.
/// **Her own** discount is the opposite: it is hers to decide, in pesos or
/// per cent, with a word about why so the figure means something at the end
/// of the month.
///
/// Either way the arithmetic — including the VAT exemption, where the shop is
/// VAT-registered — is shown in full before she commits to it.
class DiscountSheet extends ConsumerStatefulWidget {
  const DiscountSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (BuildContext context) => const DiscountSheet(),
  );

  @override
  ConsumerState<DiscountSheet> createState() => _DiscountSheetState();
}

class _DiscountSheetState extends ConsumerState<DiscountSheet> {
  late DiscountKind? _kind;
  late final TextEditingController _name;
  late final TextEditingController _idNo;
  late final TextEditingController _reason;
  late final TextEditingController _amount;

  /// How she is saying it: ₱20 off, or 10% off.
  bool _inPesos = true;

  @override
  void initState() {
    super.initState();
    final OrderDraft draft = ref.read(cartProvider);
    _kind = draft.discountKind;
    _name = TextEditingController(text: draft.discountBeneficiaryName ?? '');
    _idNo = TextEditingController(text: draft.discountBeneficiaryIdNo ?? '');
    _reason = TextEditingController(text: draft.discountReason ?? '');
    _inPesos = draft.discountRateBpOverride == null;
    _amount = TextEditingController(
      text: _inPesos
          ? (draft.discountAmountOverride == null
                ? ''
                : (draft.discountAmountOverride!.centavos / 100)
                      .toStringAsFixed(2))
          : (draft.discountRateBpOverride! / 100).toStringAsFixed(0),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _idNo.dispose();
    _reason.dispose();
    _amount.dispose();
    super.dispose();
  }

  /// What she typed, as the engine wants it. Null while the box is empty or
  /// nonsense, which simply means nothing comes off yet.
  double? get _typed {
    final double? value = double.tryParse(_amount.text.trim());
    return value == null || value <= 0 ? null : value;
  }

  Money? get _amountOff =>
      _inPesos && _typed != null ? Money((_typed! * 100).round()) : null;

  int? get _rateBpOff =>
      !_inPesos && _typed != null ? (_typed! * 100).round() : null;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final OrderDraft draft = ref.watch(cartProvider);
    final BusinessSettings settings = ref.watch(settingsControllerProvider);
    final DiscountBreakdown preview = DiscountEngine(settings).apply(
      kind: _kind,
      grossSales: draft.subtotal,
      rateBpOverride: _rateBpOff,
      amountOverride: _amountOff,
    );

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          KuboSpacing.lg,
          0,
          KuboSpacing.lg,
          KuboSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text('Discount', style: theme.textTheme.headlineSmall),
              const SizedBox(height: KuboSpacing.xs),
              Text(
                settings.statutoryDiscountsEnabled
                    ? 'Applies to the whole order. If only one person in the '
                          'group is a cardholder, ring their drink as its own '
                          'order — that is what the law entitles them to.'
                    : 'Applies to the whole order, and is printed on the '
                          'receipt.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: KuboSpacing.lg),

              RadioGroup<DiscountKind?>(
                groupValue: _kind,
                onChanged: (DiscountKind? value) =>
                    setState(() => _kind = value),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    if (settings.statutoryDiscountsEnabled)
                      for (final DiscountKind kind in <DiscountKind>[
                        DiscountKind.senior,
                        DiscountKind.pwd,
                      ])
                        RadioListTile<DiscountKind?>(
                          value: kind,
                          contentPadding: EdgeInsets.zero,
                          title: Text(kind.label),
                          subtitle: Text(
                            '${(settings.statutoryDiscountRateBp / 100).toStringAsFixed(0)}% '
                            '${settings.vatRegistered ? 'and VAT-exempt' : 'off the menu price'}',
                          ),
                        ),
                    const RadioListTile<DiscountKind?>(
                      value: DiscountKind.other,
                      contentPadding: EdgeInsets.zero,
                      title: Text('My own discount'),
                      subtitle: Text('However much you decide, this once'),
                    ),
                    const RadioListTile<DiscountKind?>(
                      value: null,
                      contentPadding: EdgeInsets.zero,
                      title: Text('No discount'),
                    ),
                  ],
                ),
              ),

              if (_kind == DiscountKind.other) ...<Widget>[
                const SizedBox(height: KuboSpacing.md),
                SegmentedButton<bool>(
                  segments: const <ButtonSegment<bool>>[
                    ButtonSegment<bool>(value: true, label: Text('₱ off')),
                    ButtonSegment<bool>(value: false, label: Text('% off')),
                  ],
                  selected: <bool>{_inPesos},
                  onSelectionChanged: (Set<bool> picked) =>
                      setState(() => _inPesos = picked.first),
                ),
                const SizedBox(height: KuboSpacing.sm),
                TextField(
                  controller: _amount,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: _inPesos ? 'How much off' : 'What per cent off',
                    prefixText: _inPesos ? '₱ ' : null,
                    suffixText: _inPesos ? null : '%',
                    helperText: _inPesos
                        ? 'More than the order simply makes it free'
                        : 'Of the whole order',
                  ),
                ),
                const SizedBox(height: KuboSpacing.sm),
                TextField(
                  controller: _reason,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'What to call it',
                    hintText: 'Friend · Opening week · Wrong order',
                    helperText:
                        'Prints on the receipt and groups it in your reports',
                  ),
                ),
              ],

              if (_kind != null) ...<Widget>[
                const SizedBox(height: KuboSpacing.md),
                _Breakdown(preview: preview, settings: settings),
              ],

              if (_kind != null && _kind!.isStatutory) ...<Widget>[
                const SizedBox(height: KuboSpacing.lg),
                Text(
                  'The law asks you to record who claimed it.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: KuboSpacing.sm),
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Name on the ID',
                  ),
                ),
                const SizedBox(height: KuboSpacing.sm),
                TextField(
                  controller: _idNo,
                  decoration: const InputDecoration(labelText: 'ID number'),
                ),
              ],

              const SizedBox(height: KuboSpacing.lg),
              FilledButton(
                onPressed: _kind == DiscountKind.other && _typed == null
                    ? null
                    : _apply,
                child: Text(_kind == null ? 'REMOVE DISCOUNT' : 'APPLY'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _apply() {
    final bool statutory = _kind?.isStatutory ?? false;
    ref
        .read(cartProvider.notifier)
        .setDiscount(
          _kind,
          beneficiaryName: statutory && _name.text.trim().isNotEmpty
              ? _name.text.trim()
              : null,
          beneficiaryIdNo: statutory && _idNo.text.trim().isNotEmpty
              ? _idNo.text.trim()
              : null,
          reason: statutory || _reason.text.trim().isEmpty
              ? null
              : _reason.text.trim(),
          amountOff: statutory ? null : _amountOff,
          rateBpOff: statutory ? null : _rateBpOff,
        );
    Navigator.of(context).pop();
  }
}

/// Every step of the sum, so the owner can hand the phone to a customer who
/// asks how the figure was reached.
class _Breakdown extends StatelessWidget {
  const _Breakdown({required this.preview, required this.settings});

  final DiscountBreakdown preview;
  final BusinessSettings settings;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    Widget row(String label, String value, {bool strong = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: strong
                  ? theme.textTheme.titleSmall
                  : theme.textTheme.bodyMedium,
            ),
          ),
          Text(
            value,
            style: strong
                ? theme.textTheme.titleSmall
                : theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );

    return Container(
      padding: const EdgeInsets.all(KuboSpacing.md),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(KuboRadius.md),
      ),
      child: Column(
        children: <Widget>[
          row('Menu total', preview.grossSales.format()),
          if (preview.vatRemoved.isPositive) ...<Widget>[
            row('Less VAT (exempt sale)', '−${preview.vatRemoved.format()}'),
            row('Net of VAT', preview.discountableBase.format()),
          ],
          row(
            'Less ${(preview.rateBp / 100).toStringAsFixed(0)}% discount',
            '−${preview.discountAmount.format()}',
          ),
          const Divider(height: KuboSpacing.lg),
          row('Amount due', preview.amountDue.format(), strong: true),
          const SizedBox(height: KuboSpacing.xs),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              'Customer saves ${preview.totalSaving.format()}',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
