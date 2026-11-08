import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/providers.dart';
import '../../../data/db/backup_service.dart';
import '../../../domain/entities/backup_entry.dart';
import 'backup_screen.dart';

/// Hands a backup file to the share sheet, and records that it left.
///
/// This is the one thing an automatic backup on the phone cannot do for her:
/// put a copy somewhere a lost phone cannot take with it. iCloud Drive,
/// Google Drive, Messenger and Mail all appear in the sheet, and each
/// receives the file itself.
///
/// Returns true if the file was handed over. A cancelled share is not a
/// failure and is not recorded as a copy.
Future<bool> sendBackupOffDevice(
  BuildContext context,
  WidgetRef ref,
  BackupEntry entry,
) async {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  final BackupService service = ref.read(backupServiceProvider);
  try {
    final ShareResult result = await Share.shareXFiles(<XFile>[
      XFile(service.pathOf(entry), name: entry.fileName),
    ], subject: 'Kubo Cà Phê backup — ${entry.fileName}');

    if (result.status != ShareResultStatus.success) return false;

    await service.markSent(entry);
    ref.invalidate(backupListProvider);
    return true;
  } on Object catch (error) {
    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(content: Text('The copy could not be sent. $error')),
      );
    return false;
  }
}

/// Whether today's work is still only on this phone.
final FutureProvider<bool> backupNeedsSendingProvider = FutureProvider<bool>((
  Ref ref,
) {
  ref.watch(salesRevisionProvider);
  ref.watch(backupListProvider);
  return ref
      .watch(backupServiceProvider)
      .needsSendingFor(ref.watch(todayBusinessDateProvider));
});
