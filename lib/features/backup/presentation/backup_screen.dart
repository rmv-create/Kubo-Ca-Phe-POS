import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/errors/app_exception.dart';
import '../../../data/cloud/cloud_backup_service.dart';
import '../../../data/cloud/cloud_backup_target.dart';
import '../../../data/db/backup_service.dart';
import '../../../domain/entities/backup_entry.dart';
import '../../../shared/widgets/section_header.dart';
import 'send_backup.dart';

/// Set once a backup has been restored over the live database. The app then
/// refuses to keep running against a file its open connection no longer
/// matches, and asks to be relaunched.
final StateProvider<bool> restartRequiredProvider = StateProvider<bool>(
  (Ref ref) => false,
);

final FutureProvider<List<BackupEntry>> backupListProvider =
    FutureProvider<List<BackupEntry>>((Ref ref) async {
      final BackupService service = ref.watch(backupServiceProvider);
      // Anything copied into the folder from another phone is picked up
      // before the list is drawn, so moving devices needs no import button.
      await service.adopt();
      return service.listBackups();
    });

class BackupScreen extends ConsumerWidget {
  const BackupScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<BackupEntry>> backups = ref.watch(backupListProvider);
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Backup')),
      body: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              KuboSpacing.lg,
              KuboSpacing.md,
              KuboSpacing.lg,
              0,
            ),
            child: Text(
              'The whole business lives in one file on this device. A backup '
              'is taken automatically once a day and before every app '
              'upgrade, and kept in the app’s folder in Files.\n\n'
              'Moving to a new phone: send a copy of the newest backup to '
              'yourself, save it into Kubo’s folder in Files on the new '
              'phone, open this screen, and restore it. Everything comes '
              'across — orders, customers, recipes, stock and settings.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          const _CloudSection(),
          if (ref.watch(backupNeedsSendingProvider).valueOrNull ?? false)
            const _StillOnThisPhone(),
          Padding(
            padding: const EdgeInsets.all(KuboSpacing.lg),
            child: FilledButton.icon(
              onPressed: () => _createBackup(context, ref),
              icon: const Icon(Icons.save_outlined),
              label: const Text('Back up now'),
            ),
          ),
          const SectionHeader(
            'Backups',
            padding: EdgeInsets.fromLTRB(
              KuboSpacing.lg,
              0,
              KuboSpacing.lg,
              KuboSpacing.sm,
            ),
          ),
          Expanded(
            child: backups.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator.adaptive()),
              error: (Object error, StackTrace stack) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(KuboSpacing.xl),
                  child: Text(
                    'The backup list could not be read.\n$error',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
              data: (List<BackupEntry> entries) => entries.isEmpty
                  ? Center(
                      child: Text(
                        'No backups yet',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: entries.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (BuildContext context, int index) =>
                          _BackupTile(entry: entries[index]),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _createBackup(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final BackupService service = ref.read(backupServiceProvider);
      final BackupEntry entry = await service.create();
      await service.prune(
        keep: ref.read(settingsControllerProvider).backupRetentionCount,
      );
      ref.invalidate(backupListProvider);
      messenger
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(content: Text('Backed up — ${entry.sizeLabel}')),
        );
    } on AppException catch (error) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}

/// Where the closing backup goes by itself, and whether it is getting there.
class _CloudSection extends ConsumerWidget {
  const _CloudSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final CloudBackupService cloud = ref.watch(cloudBackupServiceProvider);

    if (cloud.target == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          KuboSpacing.lg,
          KuboSpacing.lg,
          KuboSpacing.lg,
          0,
        ),
        child: Text(
          'Automatic cloud backup is not set up in this copy of the app. '
          'Closing the day still takes a backup, and you can send a copy of '
          'it anywhere from the list below.',
          style: theme.textTheme.bodySmall,
        ),
      );
    }

    return FutureBuilder<_CloudStatus>(
      future: _CloudStatus.of(cloud),
      builder: (BuildContext context, AsyncSnapshot<_CloudStatus> snapshot) {
        final _CloudStatus? status = snapshot.data;
        if (status == null) return const SizedBox.shrink();

        return Column(
          children: <Widget>[
            const SectionHeader('Cloud'),
            ListTile(
              leading: Icon(
                status.connected
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_off_outlined,
                color: status.connected ? null : theme.colorScheme.error,
              ),
              title: Text(
                status.connected
                    ? '${cloud.target!.label} · ${status.account ?? ''}'
                    : 'Connect ${cloud.target!.label}',
              ),
              subtitle: Text(status.describe()),
              trailing: TextButton(
                onPressed: () => _toggle(context, ref, status.connected),
                child: Text(status.connected ? 'DISCONNECT' : 'CONNECT'),
              ),
            ),
            if (status.connected)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  KuboSpacing.lg,
                  0,
                  KuboSpacing.lg,
                  KuboSpacing.sm,
                ),
                child: OutlinedButton.icon(
                  onPressed: () => _sendNow(context, ref),
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('Send the newest backup now'),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _toggle(
    BuildContext context,
    WidgetRef ref,
    bool connected,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final CloudBackupTarget target = ref
        .read(cloudBackupServiceProvider)
        .target!;
    try {
      if (connected) {
        await target.disconnect();
      } else {
        await target.connect();
      }
    } on CloudBackupException catch (error) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    }
    ref.invalidate(backupListProvider);
  }

  Future<void> _sendNow(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final CloudBackupOutcome outcome = await ref
        .read(cloudBackupServiceProvider)
        .sendNewest();
    ref.invalidate(backupListProvider);
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(outcome.message)));
  }
}

/// What to say about the cloud, gathered in one go.
class _CloudStatus {
  const _CloudStatus({
    required this.connected,
    this.account,
    this.lastUploadAt,
    this.lastError,
  });

  static Future<_CloudStatus> of(CloudBackupService cloud) async =>
      _CloudStatus(
        connected: await cloud.isConnected(),
        account: await cloud.accountLabel(),
        lastUploadAt: await cloud.lastUploadAt(),
        lastError: await cloud.lastError(),
      );

  final bool connected;
  final String? account;
  final DateTime? lastUploadAt;
  final String? lastError;

  String describe() {
    if (!connected) {
      return 'Sign in once and every closing backup goes up by itself.';
    }
    final String? problem = lastError;
    if (problem != null) return problem;
    final DateTime? last = lastUploadAt;
    if (last == null) return 'Nothing sent yet.';
    return 'Last copy '
        '${DateFormat('d MMM yyyy · HH:mm').format(last.toLocal())}';
  }
}

/// Today's work exists in one place, and that place is in her pocket.
class _StillOnThisPhone extends ConsumerWidget {
  const _StillOnThisPhone();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(
        KuboSpacing.lg,
        KuboSpacing.lg,
        KuboSpacing.lg,
        0,
      ),
      padding: const EdgeInsets.all(KuboSpacing.lg),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(KuboRadius.md),
        border: Border(
          left: BorderSide(color: theme.colorScheme.error, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Today is only on this phone',
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'A backup beside the database it came from survives a mistake, '
            'not a lost phone. Send one copy somewhere else.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onErrorContainer,
            ),
          ),
          const SizedBox(height: KuboSpacing.sm),
          FilledButton.icon(
            onPressed: () => _send(context, ref),
            icon: const Icon(Icons.ios_share),
            label: const Text('SEND A COPY'),
          ),
        ],
      ),
    );
  }

  Future<void> _send(BuildContext context, WidgetRef ref) async {
    final BackupEntry? newest = await ref.read(backupServiceProvider).newest();
    if (newest == null || !context.mounted) return;
    await sendBackupOffDevice(context, ref, newest);
  }
}

class _BackupTile extends ConsumerWidget {
  const _BackupTile({required this.entry});

  final BackupEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DateFormat format = DateFormat('d MMM yyyy · HH:mm');
    return ListTile(
      leading: Icon(
        entry.isOffDevice
            ? Icons.cloud_done_outlined
            : entry.reason.isProtected
            ? Icons.lock_outline
            : Icons.inventory_2_outlined,
      ),
      title: Text(format.format(entry.createdAt.toLocal())),
      subtitle: Text(
        '${entry.reason.label} · ${entry.sizeLabel}'
        '${entry.isOffDevice ? ' · copied off the phone' : ''}',
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (String action) => switch (action) {
          'send' => _send(context, ref),
          'verify' => _verify(context, ref),
          'restore' => _restore(context, ref),
          _ => null,
        },
        itemBuilder: (BuildContext context) => const <PopupMenuEntry<String>>[
          PopupMenuItem<String>(value: 'send', child: Text('Send a copy…')),
          PopupMenuItem<String>(value: 'verify', child: Text('Verify')),
          PopupMenuItem<String>(value: 'restore', child: Text('Restore…')),
        ],
      ),
    );
  }

  Future<void> _send(BuildContext context, WidgetRef ref) =>
      sendBackupOffDevice(context, ref, entry);

  Future<void> _verify(BuildContext context, WidgetRef ref) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool ok = await ref.read(backupServiceProvider).verify(entry);
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? 'Backup is intact.'
                : 'This backup does not match its checksum and cannot be trusted.',
          ),
        ),
      );
  }

  Future<void> _restore(BuildContext context, WidgetRef ref) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Restore this backup?'),
        content: Text(
          'Everything recorded since '
          '${DateFormat('d MMM yyyy, HH:mm').format(entry.createdAt.toLocal())} '
          'will be replaced — orders, customers, inventory and settings.\n\n'
          'The current database is backed up first, and Kubo must be closed and '
          'reopened afterwards.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(databaseProvider).close();
      await ref.read(backupServiceProvider).restore(entry);
      ref.read(restartRequiredProvider.notifier).state = true;
    } on AppException catch (error) {
      messenger
        ..clearSnackBars()
        ..showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}
