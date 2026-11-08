import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

/// Writes the export beside the backups and offers it to the share sheet.
Future<bool> saveArchive(
  String sql,
  String filename, {
  required Directory into,
}) async {
  await into.create(recursive: true);
  final File file = File(p.join(into.path, filename));
  await file.writeAsString(sql);

  final ShareResult result = await Share.shareXFiles(<XFile>[
    XFile(file.path, name: filename, mimeType: 'application/sql'),
  ], subject: 'Kubo Cà Phê — everything, as of today');
  return result.status == ShareResultStatus.success;
}

/// Reading a file back in is the Files app's job on a phone: she copies the
/// export into Kubo's folder, and it is offered from the list there.
bool get canPickArchive => false;

Future<String?> pickArchive() async => null;

/// Nothing to ask for: a file on a phone stays until it is deleted.
Future<bool> requestPersistentStorage() async => true;

/// Writes a workbook into [into] and offers it to the share sheet.
Future<bool> saveBinary(
  List<int> bytes,
  String filename, {
  required Directory into,
  String mimeType = 'application/octet-stream',
}) async {
  await into.create(recursive: true);
  final File file = File(p.join(into.path, filename));
  await file.writeAsBytes(bytes, flush: true);

  final ShareResult result = await Share.shareXFiles(<XFile>[
    XFile(file.path, name: filename, mimeType: mimeType),
  ], subject: 'Kubo Cà Phê — $filename');
  return result.status == ShareResultStatus.success;
}
