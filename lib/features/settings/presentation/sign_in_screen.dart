import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../domain/entities/app_user.dart';
import '../../../shared/widgets/kubo_mark.dart';

/// Pick a name, tap a PIN.
///
/// Shown when someone tries to open Management and either nobody is signed in
/// or the person who is may not go there. It never blocks the POS: a barista
/// who cannot see the books can still take orders all day.
class SignInSheet extends ConsumerStatefulWidget {
  const SignInSheet({super.key});

  /// Returns the person who signed in, or null if they backed out.
  static Future<AppUser?> show(BuildContext context) =>
      showModalBottomSheet<AppUser>(
        context: context,
        isScrollControlled: true,
        builder: (BuildContext context) => const SignInSheet(),
      );

  @override
  ConsumerState<SignInSheet> createState() => _SignInSheetState();
}

class _SignInSheetState extends ConsumerState<SignInSheet> {
  final TextEditingController _pin = TextEditingController();
  AppUser? _chosen;
  String? _error;
  bool _checking = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<AppUser> users =
        ref.watch(usersProvider).valueOrNull ?? const <AppUser>[];
    final AppUser? chosen = _chosen ?? (users.length == 1 ? users.first : null);

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          KuboSpacing.lg,
          KuboSpacing.xl,
          KuboSpacing.lg,
          KuboSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Center(child: KuboMark(size: 26)),
            const SizedBox(height: KuboSpacing.lg),
            Text(
              chosen == null ? 'Who is this?' : 'Hello, ${chosen.name}',
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineSmall,
            ),
            const SizedBox(height: KuboSpacing.lg),

            if (chosen == null)
              for (final AppUser user in users)
                ListTile(
                  leading: Icon(
                    user.role == UserRole.owner
                        ? Icons.workspace_premium_outlined
                        : Icons.local_cafe_outlined,
                  ),
                  title: Text(user.name),
                  subtitle: Text(user.role.label),
                  onTap: () => setState(() {
                    _chosen = user;
                    _error = null;
                  }),
                )
            else ...<Widget>[
              TextField(
                controller: _pin,
                autofocus: true,
                obscureText: true,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium,
                decoration: InputDecoration(
                  hintText: 'PIN',
                  errorText: _error,
                  counterText: '',
                ),
                maxLength: 8,
                onSubmitted: (_) => _submit(chosen),
              ),
              const SizedBox(height: KuboSpacing.lg),
              FilledButton(
                onPressed: _checking ? null : () => _submit(chosen),
                child: const Text('SIGN IN'),
              ),
              if (users.length > 1)
                TextButton(
                  onPressed: () => setState(() {
                    _chosen = null;
                    _pin.clear();
                    _error = null;
                  }),
                  child: const Text('Someone else'),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _submit(AppUser user) async {
    setState(() {
      _checking = true;
      _error = null;
    });
    final NavigatorState navigator = Navigator.of(context);
    final AppUser? signedIn = await ref
        .read(signInServiceProvider)
        .signIn(userId: user.id, pin: _pin.text.trim());

    if (!mounted) return;
    if (signedIn == null) {
      setState(() {
        _checking = false;
        // Deliberately vague about which part was wrong.
        _error = 'That PIN is not right.';
        _pin.clear();
      });
      return;
    }
    ref.read(signedInUserProvider.notifier).set(signedIn);
    navigator.pop(signedIn);
  }
}
