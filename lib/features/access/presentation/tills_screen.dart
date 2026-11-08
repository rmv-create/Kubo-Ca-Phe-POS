import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../data/cloud/shop_directory.dart';

/// Which phones are in the shop, and how another one gets in.
///
/// The owner's side of the welcome screen. She reads the invite out; the
/// barista types it; ten minutes later it is no use to anybody.
class TillsScreen extends ConsumerStatefulWidget {
  const TillsScreen({super.key});

  @override
  ConsumerState<TillsScreen> createState() => _TillsScreenState();
}

class _TillsScreenState extends ConsumerState<TillsScreen> {
  String? _invite;
  bool _working = false;
  List<AdmittedTill>? _tills;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final List<AdmittedTill> found = await ref
        .read(shopAccessServiceProvider)
        .tills();
    if (mounted) setState(() => _tills = found);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<AdmittedTill> tills = _tills ?? const <AdmittedTill>[];

    return Scaffold(
      appBar: AppBar(title: const Text('Phones in this shop')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: KuboSpacing.xxl),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.all(KuboSpacing.lg),
            child: Text(
              'Anybody can open the link. Only these phones hold your shop. '
              'A new one gets in by typing an invite you read out, and no '
              'other way.',
              style: theme.textTheme.bodyMedium,
            ),
          ),

          if (_invite != null) _InviteCard(code: _invite!),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.lg),
            child: SizedBox(
              height: KuboTouch.payButton,
              child: FilledButton.icon(
                onPressed: _working ? null : _makeInvite,
                icon: const Icon(Icons.add),
                label: Text(
                  _invite == null ? 'INVITE A PHONE' : 'A DIFFERENT INVITE',
                ),
              ),
            ),
          ),

          const SizedBox(height: KuboSpacing.xl),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: KuboSpacing.lg),
            child: Text('Let in', style: theme.textTheme.titleMedium),
          ),
          if (_tills == null)
            const Padding(
              padding: EdgeInsets.all(KuboSpacing.xl),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (tills.isEmpty)
            Padding(
              padding: const EdgeInsets.all(KuboSpacing.lg),
              child: Text(
                'Only this phone, or the shop could not be reached just now.',
                style: theme.textTheme.bodySmall,
              ),
            )
          else
            for (final AdmittedTill till in tills)
              ListTile(
                leading: Icon(
                  till.isOwner ? Icons.verified_user_outlined : Icons.smartphone,
                ),
                title: Text(till.label),
                subtitle: Text(
                  till.isOwner
                      ? 'You — everything'
                      : 'Barista — the POS only',
                ),
                trailing: till.isOwner
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.person_remove_outlined),
                        tooltip: 'Shut this phone out',
                        onPressed: () => _remove(till),
                      ),
              ),
        ],
      ),
    );
  }

  Future<void> _makeInvite() async {
    setState(() => _working = true);
    final String? code = await ref.read(shopAccessServiceProvider).newInvite();
    if (!mounted) return;
    setState(() {
      _working = false;
      _invite = code;
    });
    if (code == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not make an invite. This needs signal, and you have to '
            'be signed in as the owner.',
          ),
        ),
      );
    }
  }

  Future<void> _remove(AdmittedTill till) async {
    final bool? sure = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Shut out ${till.label}?'),
        content: const Text(
          'That phone stops being told anything new, and nothing it says '
          'afterwards is heard. What it already has stays on it — there '
          'is no way to reach into somebody else’s phone and take it '
          'back.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('SHUT IT OUT'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await ref.read(shopAccessServiceProvider).removeTill(till.uid);
    await _refresh();
  }
}

class _InviteCard extends StatelessWidget {
  const _InviteCard({required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.fromLTRB(
        KuboSpacing.lg,
        0,
        KuboSpacing.lg,
        KuboSpacing.lg,
      ),
      child: Padding(
        padding: const EdgeInsets.all(KuboSpacing.lg),
        child: Column(
          children: <Widget>[
            SelectableText(
              code,
              style: theme.textTheme.displaySmall?.copyWith(
                letterSpacing: 6,
                fontFeatures: const <FontFeature>[
                  FontFeature.tabularFigures(),
                ],
              ),
            ),
            const SizedBox(height: KuboSpacing.sm),
            Text(
              'Good for ten minutes. On her phone: open the link, tap '
              '“I have an invite”, type this.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: KuboSpacing.sm),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: code));
              },
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copy'),
            ),
          ],
        ),
      ),
    );
  }
}
