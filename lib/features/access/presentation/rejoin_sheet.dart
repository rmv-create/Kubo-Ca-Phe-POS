import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../data/db/sync/cloud_sync_service.dart';
import '../../../domain/entities/business_settings.dart';
import '../../../domain/services/shop_access_service.dart';

/// Puts a phone that has lost its place back into the shop.
///
/// A till is let in by its own sign-in id, and that id lives in the
/// browser's storage. Clear the site data, reinstall from the home screen,
/// or let the phone tidy it away while the app sat unused, and the till
/// wakes up still holding the shop's menu, still taking orders — and no
/// longer anybody the shop recognises. Everything it rings up queues, and
/// none of it goes anywhere.
///
/// That is what happened here: three hundred and fifty-seven changes
/// waiting to go and no way for them to leave. Nothing is lost by it, and
/// nothing is lost by putting it right.
///
/// How it is put right depends on whose phone it is, and getting that wrong
/// wastes a day. The **barista's** phone is admitted by an invite the owner
/// reads out. The **owner's** phone is not: she signs in with her own email
/// and password, which is the same account that owns the shop, and no
/// invite will do it — she would be inviting herself to her own shop, and
/// she cannot even make an invite while she is signed out.
class RejoinSheet extends ConsumerStatefulWidget {
  const RejoinSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (BuildContext context) => const RejoinSheet(),
  );

  @override
  ConsumerState<RejoinSheet> createState() => _RejoinSheetState();
}

class _RejoinSheetState extends ConsumerState<RejoinSheet> {
  final TextEditingController _code = TextEditingController();
  final TextEditingController _name = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  String? _problem;
  bool _busy = false;
  bool _done = false;

  /// Whether this phone is the owner's. Null until the app has been asked.
  bool? _hers;

  @override
  void initState() {
    super.initState();
    unawaited(_whosePhone());
  }

  /// What this phone was set up as.
  ///
  /// Read from the phone's own notes rather than through the service that
  /// holds the cloud pieces: which till this is was never a question for
  /// the network, and asking the network made the answer wait on a
  /// connection that, here of all places, is the thing that has gone.
  Future<void> _whosePhone() async {
    final String? role = await ref
        .read(settingsRepositoryProvider)
        .readRaw(SettingKeys.syncRole);
    // A phone that has never been told is treated as hers: she is offered a
    // sign-in, which is hers to use and which a barista cannot complete,
    // rather than an invite she has no way to make.
    if (mounted) setState(() => _hers ??= role != 'barista');
  }

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int waiting =
        ref.watch(syncStandingProvider).valueOrNull?.waiting ?? 0;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        KuboSpacing.lg,
        0,
        KuboSpacing.lg,
        KuboSpacing.lg + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Icon(
              _done ? Icons.cloud_done_outlined : Icons.sync_problem,
              size: 36,
              color: _done
                  ? theme.colorScheme.primary
                  : theme.colorScheme.error,
            ),
            const SizedBox(height: KuboSpacing.md),
            Text(
              _done
                  ? 'This phone is back in the shop'
                  : _hers == true
                  ? 'Sign this phone back in'
                  : 'Let this phone back in',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: KuboSpacing.sm),
            Text(
              _done
                  ? 'Everything it was holding is on its way to the other '
                        'phone now.'
                  : '${_hers == true ? 'This phone has been signed out of the shop, so nothing it rings up is reaching the other one. Sign in with the email and password you opened the shop with.' : 'The shop no longer recognises this phone, so nothing it rings up is reaching the other one. Ask the owner for an invite \u2014 her phone makes one under Phones in this shop \u2014 and type it here.'}'
                        '${waiting == 0 ? '' : ' $waiting '
                                  '${waiting == 1 ? 'thing is' : 'things are'} '
                                  'waiting to go, and nothing has been lost.'}',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (!_done) ...<Widget>[
              const SizedBox(height: KuboSpacing.lg),
              if (_hers == true) ...<Widget>[
                TextField(
                  controller: _email,
                  enabled: !_busy,
                  autofocus: true,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Your email'),
                ),
                const SizedBox(height: KuboSpacing.md),
                TextField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Your password'),
                  onSubmitted: (_) => _go(),
                ),
              ] else ...<Widget>[
                TextField(
                  controller: _code,
                  enabled: !_busy,
                  autofocus: true,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: <TextInputFormatter>[UpperCaseFormatter()],
                  decoration: const InputDecoration(
                    labelText: 'The invite',
                    hintText: 'EIGHT CHARACTERS',
                  ),
                ),
                const SizedBox(height: KuboSpacing.md),
                TextField(
                  controller: _name,
                  enabled: !_busy,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Whose phone is this?',
                    hintText: 'Jaja',
                  ),
                  onSubmitted: (_) => _go(),
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
              const SizedBox(height: KuboSpacing.lg),
              SizedBox(
                height: KuboTouch.primaryAction,
                child: FilledButton(
                  onPressed: _busy ? null : _go,
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(_hers == true ? 'SIGN BACK IN' : 'LET IT BACK IN'),
                ),
              ),
              // Whoever is holding the phone decides. The app only knows what
              // this till was set up as, and a phone changes hands in a small
              // shop.
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _hers = !(_hers ?? false);
                        _problem = null;
                      }),
                child: Text(
                  _hers == true
                      ? 'This is the barista\u2019s phone \u2014 use an invite'
                      : 'I am the owner \u2014 sign in instead',
                ),
              ),
            ],
            TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).pop(),
              child: Text(_done ? 'Done' : 'Not now'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _go() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _problem = null;
    });

    final ShopAccessService shop = ref.read(shopAccessServiceProvider);
    // Her own account owns the shop, so signing in is what puts her phone
    // back; an invite cannot, and she could not make one while signed out.
    final AccessOutcome outcome = _hers == true
        ? await shop.signIn(email: _email.text, password: _password.text)
        : await shop.joinWithInvite(code: _code.text, deviceLabel: _name.text);

    if (!mounted) return;
    if (!outcome.succeeded) {
      setState(() {
        _busy = false;
        _problem = outcome.problem ?? 'That did not work. Try again.';
      });
      return;
    }

    // Back in — now send everything that has been piling up.
    ref.invalidate(syncTransportProvider);
    ref.invalidate(cloudSyncProvider);
    final CloudSyncService sync = await ref.read(cloudSyncProvider.future);
    await sync.catchUp(label: await shop.deviceLabel());
    if (!mounted) return;
    ref.read(syncTickProvider.notifier).bump();
    setState(() {
      _busy = false;
      _done = true;
    });
  }
}

/// Invites are read out, and nobody reads out a lower-case letter.
class UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => TextEditingValue(
    text: newValue.text.toUpperCase(),
    selection: newValue.selection,
  );
}
