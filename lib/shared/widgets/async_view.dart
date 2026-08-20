import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/kubo_tokens.dart';

/// One place where loading and failure are rendered, so no screen invents its
/// own spinner or swallows an error into an empty list.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({
    required this.value,
    required this.builder,
    this.onRetry,
    super.key,
  });

  final AsyncValue<T> value;
  final Widget Function(BuildContext context, T data) builder;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => value.when(
    data: (T data) => builder(context, data),
    loading: () => const Center(child: CircularProgressIndicator.adaptive()),
    error: (Object error, StackTrace stack) => Center(
      child: Padding(
        padding: const EdgeInsets.all(KuboSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.error_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: KuboSpacing.md),
            Text(
              'That could not be loaded.',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: KuboSpacing.xs),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (onRetry != null) ...<Widget>[
              const SizedBox(height: KuboSpacing.lg),
              OutlinedButton(
                onPressed: onRetry,
                child: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

/// Shown when a list is legitimately empty, with the action that fills it.
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(KuboSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: KuboSpacing.md),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: KuboSpacing.xs),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            if (action != null) ...<Widget>[
              const SizedBox(height: KuboSpacing.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
