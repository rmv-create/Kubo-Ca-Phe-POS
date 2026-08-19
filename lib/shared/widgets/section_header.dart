import 'package:flutter/material.dart';

import '../../app/theme/kubo_tokens.dart';

/// The small, letter-spaced label that opens each block of the POS
/// ("CUSTOMER", "CLASSICS", "CURRENT ORDER").
class SectionHeader extends StatelessWidget {
  const SectionHeader(
    this.label, {
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(
      KuboSpacing.lg,
      KuboSpacing.xl,
      KuboSpacing.lg,
      KuboSpacing.sm,
    ),
    super.key,
  });

  final String label;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(label.toUpperCase(), style: theme.textTheme.labelSmall),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}
