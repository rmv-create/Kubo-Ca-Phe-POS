import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../data/db/sync/cloud_sync_service.dart';
import '../../../domain/services/shop_access_service.dart';

/// Lets a till back into the shop with a fresh invite.
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
/// nothing is lost by this: a new invite admits the phone under its new id
/// and the whole queue goes up on the next round.
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
  String? _problem;
  bool _busy = false;
  bool _done = false;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
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
                  : 'Let this phone back in',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: KuboSpacing.sm),
            Text(
              _done
                  ? 'Everything it was holding is on its way to the other '
                        'phone now.'
                  : 'The shop no longer recognises this phone, so nothing it '
                        'rings up is reaching the other one. '
                        '${waiting == 0 ? '' : '$waiting '
                                  '${waiting == 1 ? 'thing is' : 'things are'} '
                                  'waiting to go, and nothing has been lost. '}'
                        'Ask the owner for an invite — her phone makes one '
                        'under Phones in this shop — and type it here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (!_done) ...<Widget>[
              const SizedBox(height: KuboSpacing.lg),
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
                      : const Text('LET IT BACK IN'),
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

    final AccessOutcome outcome = await ref
        .read(shopAccessServiceProvider)
        .joinWithInvite(code: _code.text, deviceLabel: _name.text);

    if (!mounted) return;
    if (!outcome.succeeded) {
      setState(() {
        _busy = false;
        _problem = outcome.problem ?? 'That did not work. Ask for a new code.';
      });
      return;
    }

    // Admitted again — now send everything that has been piling up.
    ref.invalidate(syncTransportProvider);
    ref.invalidate(cloudSyncProvider);
    final CloudSyncService sync = await ref.read(cloudSyncProvider.future);
    await sync.catchUp(label: _name.text);
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
