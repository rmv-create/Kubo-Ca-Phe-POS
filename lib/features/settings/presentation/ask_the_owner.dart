import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../domain/services/sign_in_service.dart';

/// Her six digits, for the one thing the person at the till may not do alone.
///
/// The barista can be given leave to correct an order, because a customer
/// changing their mind is his problem to solve while they are standing
/// there. Voiding a sale, refunding it, deleting it or moving it to another
/// day are the owner's, and this is how she says yes to one of them without
/// handing over the till: she types her PIN here, the action goes ahead
/// once, and the till is still signed in as him.
///
/// Nothing is remembered. There is no "stay unlocked for ten minutes",
/// because the whole value of it is that she was there for that one thing.
class AskTheOwner extends ConsumerStatefulWidget {
  const AskTheOwner({required this.what, super.key});

  /// What she is being asked to allow, in her own words: "void 1111".
  final String what;

  /// Returns her name when she allowed it, and null when she did not.
  static Future<String?> show(BuildContext context, {required String what}) =>
      showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (BuildContext context) => AskTheOwner(what: what),
      );

  @override
  ConsumerState<AskTheOwner> createState() => _AskTheOwnerState();
}

class _AskTheOwnerState extends ConsumerState<AskTheOwner> {
  final TextEditingController _pin = TextEditingController();
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

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          KuboSpacing.lg,
          0,
          KuboSpacing.lg,
          KuboSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Icon(
              Icons.workspace_premium_outlined,
              size: 36,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: KuboSpacing.md),
            Text(
              'This one is the owner’s',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: KuboSpacing.sm),
            Text(
              'Ask her to type her PIN to ${widget.what}. It allows this one '
              'thing, now — the till stays signed in as you.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: KuboSpacing.lg),
            TextField(
              controller: _pin,
              autofocus: true,
              obscureText: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              style: theme.textTheme.headlineMedium,
              decoration: InputDecoration(
                hintText: '${SignInService.pinLength} digits',
                errorText: _error,
                counterText: '',
              ),
              maxLength: SignInService.pinLength,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              // The PIN is a known length, so the sixth digit is the whole
              // instruction.
              onChanged: (String value) {
                if (value.length == SignInService.pinLength) _submit();
              },
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: KuboSpacing.lg),
            FilledButton(
              onPressed: _checking ? null : _submit,
              child: const Text('ALLOW IT'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Never mind'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    final NavigatorState navigator = Navigator.of(context);
    final String? owner = await ref
        .read(signInServiceProvider)
        .ownerSaysYes(_pin.text.trim());

    if (!mounted) return;
    if (owner == null) {
      setState(() {
        _checking = false;
        _error = 'That is not the owner’s PIN.';
        _pin.clear();
      });
      return;
    }
    navigator.pop(owner);
  }
}
