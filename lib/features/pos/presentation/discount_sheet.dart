import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../domain/entities/business_settings.dart';
import '../../../domain/entities/order_draft.dart';
import '../../../domain/services/discount_engine.dart';
import '../state/cart_controller.dart';

/// Applies a Senior Citizen or PWD discount to the whole order.
///
/// The owner never types an amount. She picks who is in front of her, and the
/// arithmetic — including the VAT exemption, if the shop is VAT-registered —
/// is shown before she commits to it.
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

  @override
  void initState() {
    super.initState();
    final OrderDraft draft = ref.read(cartProvider);
    _kind = draft.discountKind;
    _name = TextEditingController(text: draft.discountBeneficiaryName ?? '');
    _idNo = TextEditingController(text: draft.discountBeneficiaryIdNo ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _idNo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final OrderDraft draft = ref.watch(cartProvider);
    final BusinessSettings settings = ref.watch(settingsControllerProvider);
    final DiscountBreakdown preview = DiscountEngine(
      settings,
    ).apply(kind: _kind, grossSales: draft.subtotal);

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
                'Applies to the whole order. If only one person in the group '
                'is a cardholder, ring their drink as its own order — that is '
                'what the law entitles them to.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: KuboSpacing.lg),

              for (final DiscountKind kind in <DiscountKind>[
                DiscountKind.senior,
                DiscountKind.pwd,
              ])
                RadioListTile<DiscountKind?>(
                  value: kind,
                  groupValue: _kind,
                  contentPadding: EdgeInsets.zero,
                  title: Text(kind.label),
                  subtitle: Text(
                    '${(settings.statutoryDiscountRateBp / 100).toStringAsFixed(0)}% '
                    '${settings.vatRegistered ? 'and VAT-exempt' : 'off the menu price'}',
                  ),
                  onChanged: (DiscountKind? value) =>
                      setState(() => _kind = value),
                ),
              RadioListTile<DiscountKind?>(
                value: null,
                groupValue: _kind,
                contentPadding: EdgeInsets.zero,
                title: const Text('No discount'),
                onChanged: (DiscountKind? value) =>
                    setState(() => _kind = null),
              ),

              if (_kind != null) ...<Widget>[
                const SizedBox(height: KuboSpacing.md),
                _Breakdown(preview: preview, settings: settings),
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
                onPressed: _apply,
                child: Text(_kind == null ? 'REMOVE DISCOUNT' : 'APPLY'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _apply() {
    ref
        .read(cartProvider.notifier)
        .setDiscount(
          _kind,
          beneficiaryName: _name.text.trim().isEmpty ? null : _name.text.trim(),
          beneficiaryIdNo: _idNo.text.trim().isEmpty ? null : _idNo.text.trim(),
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
