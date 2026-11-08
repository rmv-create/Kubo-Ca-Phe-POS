import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../domain/services/shop_access_service.dart';
import '../../../shared/widgets/kubo_mark.dart';

/// The first thing anybody sees on a phone that holds no shop.
///
/// It is the whole answer to "anyone with the link can get in". They can
/// load the page — that is what a web address is, and no amount of code
/// changes it — but this is all it is. No menu, no prices, no takings, and
/// no setup wizard standing open. Three doors, and all three are locked.
class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

enum _Door { none, signIn, join, open }

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  _Door _door = _Door.none;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(KuboSpacing.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SizedBox(height: KuboSpacing.xl),
                  const Center(child: KuboMark(size: 56)),
                  const SizedBox(height: KuboSpacing.lg),
                  Text(
                    'Kubo Cà Phê',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: KuboSpacing.xs),
                  Text(
                    switch (_door) {
                      _Door.none => 'This phone is not in a shop yet.',
                      _Door.signIn => 'Sign in as the owner',
                      _Door.join => 'Join with an invite',
                      _Door.open => 'Open your shop',
                    },
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: KuboSpacing.xxl),
                  switch (_door) {
                    _Door.none => _Doors(onPick: (_Door d) => setState(() => _door = d)),
                    _Door.signIn => _AccountForm(
                      key: const ValueKey<String>('signIn'),
                      isNewShop: false,
                      onBack: _back,
                    ),
                    _Door.open => _AccountForm(
                      key: const ValueKey<String>('open'),
                      isNewShop: true,
                      onBack: _back,
                    ),
                    _Door.join => _JoinForm(onBack: _back),
                  },
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _back() => setState(() => _door = _Door.none);
}

class _Doors extends StatelessWidget {
  const _Doors({required this.onPick});

  final void Function(_Door) onPick;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        SizedBox(
          height: KuboTouch.payButton,
          child: FilledButton(
            onPressed: () => onPick(_Door.signIn),
            child: const Text('SIGN IN AS THE OWNER'),
          ),
        ),
        const SizedBox(height: KuboSpacing.sm),
        SizedBox(
          height: KuboTouch.payButton,
          child: OutlinedButton(
            onPressed: () => onPick(_Door.join),
            child: const Text('I HAVE AN INVITE'),
          ),
        ),
        const SizedBox(height: KuboSpacing.xxl),
        Text(
          'Working here? Ask the owner for an invite. It is eight '
          'characters and lasts ten minutes.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: KuboSpacing.lg),
        const Divider(),
        const SizedBox(height: KuboSpacing.sm),
        TextButton(
          onPressed: () => onPick(_Door.open),
          child: const Text('Opening a shop for the first time'),
        ),
      ],
    );
  }
}

/// Signing in, or opening a shop. The same two fields either way; what
/// differs is whether the account is being made or found.
class _AccountForm extends ConsumerStatefulWidget {
  const _AccountForm({required this.isNewShop, required this.onBack, super.key});

  final bool isNewShop;
  final VoidCallback onBack;

  @override
  ConsumerState<_AccountForm> createState() => _AccountFormState();
}

class _AccountFormState extends ConsumerState<_AccountForm> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _busy = false;
  bool _hidden = true;
  String? _problem;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: _email,
          enabled: !_busy,
          autofillHints: const <String>[AutofillHints.email],
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        const SizedBox(height: KuboSpacing.sm),
        TextField(
          controller: _password,
          enabled: !_busy,
          obscureText: _hidden,
          autofillHints: const <String>[AutofillHints.password],
          decoration: InputDecoration(
            labelText: 'Password',
            helperText: widget.isNewShop ? 'At least six characters' : null,
            suffixIcon: IconButton(
              icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _hidden = !_hidden),
            ),
          ),
          onSubmitted: (_) => _go(),
        ),
        if (_problem != null) ...<Widget>[
          const SizedBox(height: KuboSpacing.md),
          Text(
            _problem!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: KuboSpacing.lg),
        SizedBox(
          height: KuboTouch.payButton,
          child: FilledButton(
            onPressed: _busy ? null : _go,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(widget.isNewShop ? 'OPEN THE SHOP' : 'SIGN IN'),
          ),
        ),
        const SizedBox(height: KuboSpacing.sm),
        TextButton(onPressed: _busy ? null : widget.onBack, child: const Text('Back')),
        if (widget.isNewShop) ...<Widget>[
          const SizedBox(height: KuboSpacing.md),
          Text(
            'This makes the shop and puts your menu on this phone. Do it '
            'once. Everywhere else — your other phone, your barista — '
            'signs in or joins instead.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Future<void> _go() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _problem = null;
    });

    final ShopAccessService access = ref.read(shopAccessServiceProvider);
    final AccessOutcome outcome = widget.isNewShop
        ? await access.openShop(
            email: _email.text,
            password: _password.text,
          )
        : await access.signIn(email: _email.text, password: _password.text);

    if (!mounted) return;
    if (outcome.succeeded) {
      ref.invalidate(shopStandingProvider);
      return;
    }
    setState(() {
      _busy = false;
      _problem = outcome.problem;
    });
  }
}

class _JoinForm extends ConsumerStatefulWidget {
  const _JoinForm({required this.onBack});

  final VoidCallback onBack;

  @override
  ConsumerState<_JoinForm> createState() => _JoinFormState();
}

class _JoinFormState extends ConsumerState<_JoinForm> {
  final TextEditingController _code = TextEditingController();
  final TextEditingController _name = TextEditingController();
  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        TextField(
          controller: _code,
          enabled: !_busy,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          autocorrect: false,
          style: const TextStyle(letterSpacing: 3, fontSize: 20),
          decoration: const InputDecoration(
            labelText: 'Invite',
            hintText: 'K7PQ-M39X',
          ),
        ),
        const SizedBox(height: KuboSpacing.sm),
        TextField(
          controller: _name,
          enabled: !_busy,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Whose phone is this?',
            hintText: 'Ana',
            helperText: 'So the owner can tell the tills apart',
          ),
          onSubmitted: (_) => _go(),
        ),
        if (_problem != null) ...<Widget>[
          const SizedBox(height: KuboSpacing.md),
          Text(
            _problem!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: KuboSpacing.lg),
        SizedBox(
          height: KuboTouch.payButton,
          child: FilledButton(
            onPressed: _busy ? null : _go,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('JOIN'),
          ),
        ),
        const SizedBox(height: KuboSpacing.sm),
        TextButton(onPressed: _busy ? null : widget.onBack, child: const Text('Back')),
        const SizedBox(height: KuboSpacing.md),
        Text(
          'Joining needs signal, just this once. Afterwards the till works '
          'with no internet at all.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  Future<void> _go() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _problem = null;
    });

    final AccessOutcome outcome = await ref
        .read(shopAccessServiceProvider)
        .joinWithInvite(code: _code.text, deviceLabel: _name.text);

    if (!mounted) return;
    if (outcome.succeeded) {
      ref.invalidate(shopStandingProvider);
      return;
    }
    setState(() {
      _busy = false;
      _problem = outcome.problem;
    });
  }
}
