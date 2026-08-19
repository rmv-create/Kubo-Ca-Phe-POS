import 'package:flutter/material.dart';

import '../../core/money/money.dart';

/// Renders a [Money] amount. Every peso figure in the app goes through this
/// widget so formatting can never drift between screens.
class MoneyText extends StatelessWidget {
  const MoneyText(
    this.amount, {
    this.style,
    this.emphasised = false,
    this.signed = false,
    super.key,
  });

  final Money amount;
  final TextStyle? style;

  /// Larger and heavier — for totals and the amount due.
  final bool emphasised;

  /// Shows a leading `+` on positive amounts, for adjustments and deltas.
  final bool signed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle base =
        style ??
        (emphasised
            ? theme.textTheme.headlineSmall!
            : theme.textTheme.bodyLarge!);
    final String prefix = signed && amount.isPositive ? '+' : '';
    return Text(
      '$prefix${amount.format()}',
      style: base.copyWith(
        fontWeight: emphasised ? FontWeight.w700 : base.fontWeight,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    );
  }
}
