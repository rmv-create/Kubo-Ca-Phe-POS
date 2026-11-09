import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/errors/app_exception.dart';
import '../../../data/cloud/account_service.dart';
import '../../../domain/entities/app_user.dart';
import '../../../domain/services/sign_in_service.dart';
import '../../../shared/widgets/kubo_mark.dart';

/// The door. Nothing of the shop is built behind it until somebody signs in.
///
/// The app used to leave the POS open to anybody holding the phone, on the
/// reasoning that whoever is on shift should be able to serve all day
/// without being asked who they are. That is true of a till bolted to a
/// counter. This one is a phone that goes home in somebody's pocket, and
/// the owner asked for a door — so there is one.
///
/// What is behind it still depends on who signs in: the barista gets the
/// POS, and the books stay the owner's.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  AppUser? _chosen;
  String _pin = '';
  String? _error;
  bool _checking = false;
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<AppUser> users =
        ref.watch(usersProvider).valueOrNull ?? const <AppUser>[];
    final AppUser? chosen = _chosen ?? (users.length == 1 ? users.first : null);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(KuboSpacing.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const Center(child: KuboMark(size: 44)),
                  const SizedBox(height: KuboSpacing.lg),
                  Text(
                    chosen == null ? 'Who is this?' : chosen.name,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: KuboSpacing.xl),

                  if (chosen == null)
                    for (final AppUser user in users)
                      Card(
                        margin: const EdgeInsets.only(bottom: KuboSpacing.sm),
                        child: ListTile(
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
                        ),
                      )
                  else ...<Widget>[
                    _Dots(
                      filled: _pin.length,
                      of: SignInService.pinLength,
                      wrong: _error != null,
                    ),
                    if (_error != null) ...<Widget>[
                      const SizedBox(height: KuboSpacing.md),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: KuboSpacing.xl),
                    _Keypad(
                      enabled: !_checking,
                      onDigit: (int d) => _type('$d', chosen),
                      onBack: () => setState(() {
                        if (_pin.isNotEmpty) {
                          _pin = _pin.substring(0, _pin.length - 1);
                        }
                        _error = null;
                      }),
                    ),
                    if (users.length > 1)
                      TextButton(
                        onPressed: () => setState(() {
                          _chosen = null;
                          _pin = '';
                          _error = null;
                        }),
                        child: const Text('Somebody else'),
                      ),
                    if (chosen.role == UserRole.owner)
                      TextButton(
                        onPressed: _busy ? null : _forgotten,
                        child: const Text('I have forgotten my PIN'),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _type(String digit, AppUser who) {
    if (_checking || _pin.length >= SignInService.pinLength) return;
    setState(() {
      _pin += digit;
      _error = null;
    });
    // The PIN is a known length, so the sixth digit is the whole
    // instruction. Making her reach for a button afterwards would be a tap
    // the app already has enough information to skip.
    if (_pin.length == SignInService.pinLength) _submit(who);
  }

  Future<void> _submit(AppUser who) async {
    setState(() => _checking = true);
    final AppUser? signedIn = await ref
        .read(signInServiceProvider)
        .signIn(userId: who.id, pin: _pin);

    if (!mounted) return;
    if (signedIn == null) {
      await HapticFeedback.heavyImpact();
      setState(() {
        _checking = false;
        _pin = '';
        _error = 'That is not the PIN.';
      });
      return;
    }
    ref.read(signedInUserProvider.notifier).set(signedIn);
  }

  /// The way back in, for the one person who cannot be locked out.
  ///
  /// A PIN is kept on the phone and nowhere else, so there is nobody to
  /// ask. What she does have is the shop's own account — the email and
  /// password that make the shop hers — and proving that is at least as
  /// strong as knowing six digits.
  ///
  /// A barista has no such door: hers is reset by the owner.
  Future<void> _forgotten() async {
    final AppUser? owner = _chosen;
    if (owner == null) return;

    final _Credentials? said = await showDialog<_Credentials>(
      context: context,
      builder: (BuildContext context) => const _ForgottenDialog(),
    );
    if (said == null || !mounted) return;

    setState(() {
      _busy = true;
      _checking = true;
      _error = null;
    });

    final AccountOutcome who = await ref
        .read(accountServiceProvider)
        .signIn(email: said.email, password: said.password);

    if (!mounted) return;
    if (!who.succeeded) {
      setState(() {
        _busy = false;
        _checking = false;
        _error = who.problem;
      });
      return;
    }

    try {
      await ref
          .read(signInServiceProvider)
          .setPin(userId: owner.id, pin: said.newPin);
      ref.read(userRevisionProvider.notifier).bump();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _checking = false;
        _pin = '';
        _error = null;
      });
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(content: Text('New PIN set. Use it now.')),
        );
    } on AppException catch (error) {
      setState(() {
        _busy = false;
        _checking = false;
        _error = error.message;
      });
    }
  }
}

class _Credentials {
  const _Credentials({
    required this.email,
    required this.password,
    required this.newPin,
  });

  final String email;
  final String password;
  final String newPin;
}

/// Email, password, and the PIN she would like instead.
class _ForgottenDialog extends StatefulWidget {
  const _ForgottenDialog();

  @override
  State<_ForgottenDialog> createState() => _ForgottenDialogState();
}

class _ForgottenDialogState extends State<_ForgottenDialog> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _pin = TextEditingController();

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Set a new PIN'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text(
            'Sign in with the shop\u2019s email and password, and choose a '
            'new PIN. This needs signal.',
          ),
          const SizedBox(height: KuboSpacing.md),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Email'),
          ),
          const SizedBox(height: KuboSpacing.sm),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
          ),
          const SizedBox(height: KuboSpacing.sm),
          TextField(
            controller: _pin,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: SignInService.pinLength,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
            decoration: const InputDecoration(
              labelText: 'New PIN',
              counterText: '',
              hintText: '6 digits',
            ),
          ),
        ],
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (_pin.text.trim().length != SignInService.pinLength) return;
          Navigator.of(context).pop(
            _Credentials(
              email: _email.text,
              password: _password.text,
              newPin: _pin.text.trim(),
            ),
          );
        },
        child: const Text('SET IT'),
      ),
    ],
  );
}

/// Six dots rather than six asterisks in a text field: it reads at arm's
/// length, which is how a phone on a counter is usually read.
class _Dots extends StatelessWidget {
  const _Dots({required this.filled, required this.of, required this.wrong});

  final int filled;
  final int of;
  final bool wrong;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        for (int i = 0; i < of; i++)
          Container(
            width: 14,
            height: 14,
            margin: const EdgeInsets.symmetric(horizontal: 7),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < filled
                  ? (wrong
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary)
                  : Colors.transparent,
              border: Border.all(
                color: wrong
                    ? theme.colorScheme.error
                    : theme.colorScheme.outlineVariant,
                width: 1.5,
              ),
            ),
          ),
      ],
    );
  }
}

/// Big numbers, because this is tapped with one thumb while holding a cup.
class _Keypad extends StatelessWidget {
  const _Keypad({
    required this.onDigit,
    required this.onBack,
    required this.enabled,
  });

  final void Function(int) onDigit;
  final VoidCallback onBack;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    Widget key(Widget child, VoidCallback? onTap) => SizedBox(
      height: 64,
      child: TextButton(
        onPressed: enabled ? onTap : null,
        style: TextButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KuboRadius.md),
          ),
        ),
        child: child,
      ),
    );

    Widget digit(int d) => key(
      Text('$d', style: theme.textTheme.headlineMedium),
      () => onDigit(d),
    );

    return Column(
      children: <Widget>[
        for (final List<int> row in <List<int>>[
          <int>[1, 2, 3],
          <int>[4, 5, 6],
          <int>[7, 8, 9],
        ])
          Row(
            children: <Widget>[
              for (final int d in row) Expanded(child: digit(d)),
            ],
          ),
        Row(
          children: <Widget>[
            const Expanded(child: SizedBox()),
            Expanded(child: digit(0)),
            Expanded(child: key(const Icon(Icons.backspace_outlined), onBack)),
          ],
        ),
      ],
    );
  }
}
