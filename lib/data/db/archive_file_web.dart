import 'dart:convert';
import 'dart:io' show Directory;
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Hands the browser a file to download.
///
/// This is the browser's whole answer to "save this somewhere": the file
/// lands wherever downloads go, and on an iPhone that is the Files app, from
/// where it can go to iCloud Drive, Google Drive or a message.
Future<bool> saveArchive(
  String sql,
  String filename, {
  required Directory into,
}) async {
  final web.Blob blob = web.Blob(
    <JSAny>[sql.toJS].toJS,
    web.BlobPropertyBag(type: 'application/sql;charset=utf-8'),
  );
  final String url = web.URL.createObjectURL(blob);
  final web.HTMLAnchorElement anchor =
      web.document.createElement('a') as web.HTMLAnchorElement
        ..href = url
        ..download = filename;
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  // Freed at once: the file has already been handed to the browser, and a
  // blob left dangling holds the whole database in memory.
  web.URL.revokeObjectURL(url);
  return true;
}

bool get canPickArchive => true;

/// Opens the file picker and reads what she chooses.
///
/// Returns null if she closes the picker without choosing, which is not an
/// error and must not be reported as one.
Future<String?> pickArchive() async {
  final web.HTMLInputElement input =
      web.document.createElement('input') as web.HTMLInputElement
        ..type = 'file'
        ..accept = '.sql,text/plain,application/sql';
  input.click();

  await input.onChange.first;
  final web.FileList? files = input.files;
  if (files == null || files.length == 0) return null;

  final web.File file = files.item(0)!;
  final web.FileReader reader = web.FileReader()..readAsArrayBuffer(file);
  await reader.onLoadEnd.first;

  final JSAny? result = reader.result;
  if (result == null) return null;
  return utf8.decode(
    (result as JSArrayBuffer).toDart.asUint8List(),
    allowMalformed: true,
  );
}

/// Asks the browser not to evict the shop's data.
///
/// Granted without a prompt for a site added to the home screen; declined
/// quietly otherwise. Either way the app carries on — this only shortens the
/// odds, and a downloaded file is what actually protects her.
Future<bool> requestPersistentStorage() async {
  try {
    return (await web.window.navigator.storage.persist().toDart).toDart;
  } on Object {
    return false;
  }
}
