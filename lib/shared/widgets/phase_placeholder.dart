import 'package:flutter/material.dart';

import '../../app/theme/kubo_tokens.dart';

/// An honest placeholder.
///
/// The app is built in phases; a screen that is not finished says so plainly
/// rather than pretending to work. Nothing here writes to the database.
class PhasePlaceholder extends StatelessWidget {
  const PhasePlaceholder({
    required this.title,
    required this.phase,
    required this.summary,
    this.bullets = const <String>[],
    this.icon = Icons.construction_outlined,
    super.key,
  });

  final String title;
  final String phase;
  final String summary;
  final List<String> bullets;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(KuboSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(KuboSpacing.md),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(KuboRadius.md),
                ),
                child: Icon(
                  icon,
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
              const SizedBox(height: KuboSpacing.lg),
              Text(title, style: theme.textTheme.headlineSmall),
              const SizedBox(height: KuboSpacing.xs),
              Text(
                phase,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.secondary,
                ),
              ),
              const SizedBox(height: KuboSpacing.md),
              Text(summary, style: theme.textTheme.bodyMedium),
              if (bullets.isNotEmpty) ...<Widget>[
                const SizedBox(height: KuboSpacing.lg),
                for (final String bullet in bullets)
                  Padding(
                    padding: const EdgeInsets.only(bottom: KuboSpacing.sm),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.only(top: 6, right: 10),
                          child: Container(
                            width: 5,
                            height: 5,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.outline,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            bullet,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
