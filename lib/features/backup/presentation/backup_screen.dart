import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/errors/app_exception.dart';
import '../../../data/db/backup_service.dart';
import '../../../domain/entities/backup_entry.dart';
import '../../../shared/widgets/section_header.dart';

/// Set once a backup has been restored over the live database. The app then
/// refuses to keep running against a file its open connection no longer
/// matches, and asks to be relaunched.
final StateProvider<bool> restartRequiredProvider = StateProvider<bool>(
  (Ref ref) => false,
);

final FutureProvider<List<BackupEntry>> backupListProvider =
    FutureProvider<List<BackupEntry>>(
      (Ref ref) => ref.watch(backupServiceProvider).listBackups(),
    );

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
              'The whole business lives in one file on this device. A backup is '
              'taken automatically once a day and before every app upgrade. '
              'Backups are saved in the app’s Documents folder, so they can '
              'be copied off the device with the Files app.',
              style: theme.textTheme.bodySmall,
            ),
          ),
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

class _BackupTile extends ConsumerWidget {
  const _BackupTile({required this.entry});

  final BackupEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final DateFormat format = DateFormat('d MMM yyyy · HH:mm');
    return ListTile(
      leading: Icon(
        entry.reason.isProtected
            ? Icons.lock_outline
            : Icons.inventory_2_outlined,
      ),
      title: Text(format.format(entry.createdAt.toLocal())),
      subtitle: Text(
        '${entry.reason.label} · ${entry.sizeLabel} · schema v${entry.schemaVersion}',
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (String action) => switch (action) {
          'verify' => _verify(context, ref),
          'restore' => _restore(context, ref),
          _ => null,
        },
        itemBuilder: (BuildContext context) => const <PopupMenuEntry<String>>[
          PopupMenuItem<String>(value: 'verify', child: Text('Verify')),
          PopupMenuItem<String>(value: 'restore', child: Text('Restore…')),
        ],
      ),
    );
  }

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
