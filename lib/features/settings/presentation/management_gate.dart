import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../domain/entities/app_user.dart';
import 'sign_in_screen.dart';

/// Stands in front of everything in the Management area.
///
/// While nobody has been set up, it lets everything through — an app that
/// locked the owner out of her own books before she had made an account would
/// be broken, not safe. Once she has added herself, a barista signed in at the
/// till sees this instead of the takings.
///
/// The POS is never gated. Whoever is on shift can serve all day.
class ManagementGate extends ConsumerWidget {
  const ManagementGate({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(canManageProvider)) return child;

    final ThemeData theme = Theme.of(context);
    final AppUser? user = ref.watch(signedInUserProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Management')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(KuboSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.lock_outline,
                size: 44,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: KuboSpacing.lg),
              Text(
                user == null
                    ? 'Sign in to open the books'
                    : 'This part is the owner’s',
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: KuboSpacing.sm),
              Text(
                user == null
                    ? 'Orders, costs, recipes, stock and settings live behind '
                          'a PIN.'
                    : 'Signed in as ${user.name}. The POS is yours; the '
                          'business side is not.',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: KuboSpacing.xl),
              FilledButton(
                onPressed: () => SignInSheet.show(context),
                child: Text(
                  user == null ? 'SIGN IN' : 'SIGN IN AS SOMEONE ELSE',
                ),
              ),
              if (user != null)
                TextButton(
                  onPressed: () =>
                      ref.read(signedInUserProvider.notifier).signOut(),
                  child: const Text('Sign out'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
