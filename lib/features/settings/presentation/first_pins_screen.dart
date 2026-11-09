import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/errors/app_exception.dart';
import '../../../domain/entities/app_user.dart';
import '../../../domain/services/sign_in_service.dart';
import '../../../shared/widgets/kubo_mark.dart';

/// The first thing a shop with no people in it asks for.
///
/// This used to be buried in Manage → Who can sign in, and nothing ever
/// pointed at it — so a shop could trade for a month with no PIN on it and
/// nobody would be told. A lock nobody is asked to set is not a lock.
///
/// The owner's PIN is required. The barista's is not: she may be working
/// alone for now, and an app that insists on inventing a second person
/// before it will sell a coffee would be wrong about her shop.
class FirstPinsScreen extends ConsumerStatefulWidget {
  const FirstPinsScreen({super.key});

  @override
  ConsumerState<FirstPinsScreen> createState() => _FirstPinsScreenState();
}

class _FirstPinsScreenState extends ConsumerState<FirstPinsScreen> {
  final TextEditingController _ownerName = TextEditingController();
  final TextEditingController _ownerPin = TextEditingController();
  final TextEditingController _baristaName = TextEditingController();
  final TextEditingController _baristaPin = TextEditingController();
  bool _addBarista = false;
  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    _ownerName.dispose();
    _ownerPin.dispose();
    _baristaName.dispose();
    _baristaPin.dispose();
    super.dispose();
  }

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
                  const Center(child: KuboMark(size: 44)),
                  const SizedBox(height: KuboSpacing.lg),
                  Text(
                    'Put a lock on it',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  const SizedBox(height: KuboSpacing.xs),
                  Text(
                    'Nobody gets into Kubo without one of these. Six digits '
                    'each, and not the same two.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: KuboSpacing.xl),

                  Text('You', style: theme.textTheme.titleMedium),
                  const SizedBox(height: KuboSpacing.sm),
                  TextField(
                    controller: _ownerName,
                    enabled: !_busy,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'Your name',
                      hintText: 'Ate',
                    ),
                  ),
                  const SizedBox(height: KuboSpacing.sm),
                  _PinField(controller: _ownerPin, enabled: !_busy),
                  Padding(
                    padding: const EdgeInsets.only(top: KuboSpacing.xs),
                    child: Text(
                      'Opens everything: the takings, the costs, the '
                      'recipes, the settings.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),

                  const SizedBox(height: KuboSpacing.lg),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _addBarista,
                    title: const Text('Somebody else serves too'),
                    subtitle: const Text(
                      'You can add them later instead — Manage → '
                      'Who can sign in',
                    ),
                    onChanged: _busy
                        ? null
                        : (bool v) => setState(() => _addBarista = v),
                  ),
                  if (_addBarista) ...<Widget>[
                    const SizedBox(height: KuboSpacing.sm),
                    TextField(
                      controller: _baristaName,
                      enabled: !_busy,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Their name',
                        hintText: 'Ana',
                      ),
                    ),
                    const SizedBox(height: KuboSpacing.sm),
                    _PinField(controller: _baristaPin, enabled: !_busy),
                    Padding(
                      padding: const EdgeInsets.only(top: KuboSpacing.xs),
                      child: Text(
                        'Opens the POS and the receipts. Not the takings, '
                        'not the costs.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],

                  if (_problem != null) ...<Widget>[
                    const SizedBox(height: KuboSpacing.md),
                    Text(
                      _problem!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],

                  const SizedBox(height: KuboSpacing.xl),
                  SizedBox(
                    height: KuboTouch.payButton,
                    child: FilledButton(
                      onPressed: _busy ? null : _save,
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('LOCK IT'),
                    ),
                  ),
                  const SizedBox(height: KuboSpacing.md),
                  Text(
                    'Write them down somewhere that is not this phone. '
                    'Forgetting the owner’s PIN means signing in with '
                    'the shop’s email and password to set a new one.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    final String ownerName = _ownerName.text.trim();
    final String ownerPin = _ownerPin.text.trim();
    final String baristaName = _baristaName.text.trim();
    final String baristaPin = _baristaPin.text.trim();

    String? wrong;
    if (ownerName.isEmpty) {
      wrong = 'Your name, so the app knows who rang up what.';
    } else if (ownerPin.length != SignInService.pinLength) {
      wrong = 'Your PIN needs ${SignInService.pinLength} digits.';
    } else if (_addBarista) {
      if (baristaName.isEmpty) {
        wrong = 'Their name too.';
      } else if (baristaPin.length != SignInService.pinLength) {
        wrong = 'Their PIN needs ${SignInService.pinLength} digits.';
      } else if (baristaPin == ownerPin) {
        // Two people sharing one PIN is one person as far as the activity
        // trail is concerned, which defeats the point of having two.
        wrong = 'Give them a different PIN from yours.';
      }
    }
    if (wrong != null) {
      setState(() => _problem = wrong);
      return;
    }

    setState(() {
      _busy = true;
      _problem = null;
    });

    try {
      final SignInService service = ref.read(signInServiceProvider);
      final AppUser owner = await service.addUser(
        name: ownerName,
        role: UserRole.owner,
        pin: ownerPin,
      );
      if (_addBarista) {
        await service.addUser(
          name: baristaName,
          role: UserRole.barista,
          pin: baristaPin,
        );
      }
      ref.invalidate(usersProvider);
      // Straight in as herself, rather than making her type the PIN she has
      // this second finished choosing.
      ref.read(signedInUserProvider.notifier).set(owner);
    } on AppException catch (error) {
      setState(() {
        _busy = false;
        _problem = error.message;
      });
    }
  }
}

class _PinField extends StatelessWidget {
  const _PinField({required this.controller, required this.enabled});

  final TextEditingController controller;
  final bool enabled;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    enabled: enabled,
    obscureText: true,
    keyboardType: TextInputType.number,
    maxLength: SignInService.pinLength,
    inputFormatters: <TextInputFormatter>[
      FilteringTextInputFormatter.digitsOnly,
    ],
    decoration: const InputDecoration(
      labelText: 'PIN',
      counterText: '',
      hintText: '6 digits',
    ),
  );
}
