import 'dart:convert';
import 'dart:io' show Directory;
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Hands the file to whatever the phone can send it to.
///
/// On an iPhone this is the share sheet, which is the only route that puts
/// the file straight into Google Drive — one tap on "Drive" rather than a
/// download, then Files, then move it. If the phone has no share sheet, or
/// she dismisses it, the file is downloaded instead, which on iOS lands in
/// Files and on a computer lands wherever downloads go.
///
/// Both paths end with the file off Kubo and in her hands, which is the
/// whole point: a copy that does not depend on the shop's own cloud still
/// being there.
Future<bool> saveArchive(
  String sql,
  String filename, {
  required Directory into,
}) async {
  final web.Blob blob = web.Blob(
    <JSAny>[sql.toJS].toJS,
    web.BlobPropertyBag(type: 'application/sql;charset=utf-8'),
  );

  if (await _shareFile(blob, filename)) return true;

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

/// Offers the file to the phone's own share sheet.
///
/// Returns false when this browser cannot share files at all, so the caller
/// can fall back to a download. A share the owner cancels also comes back
/// false — she is then handed the download, which is not what she asked for
/// but is better than nothing happening.
Future<bool> _shareFile(web.Blob blob, String filename) async {
  try {
    final web.Navigator navigator = web.window.navigator;
    final web.File file = web.File(
      <JSAny>[blob].toJS,
      filename,
      web.FilePropertyBag(type: 'application/sql'),
    );
    final web.ShareData data = web.ShareData(
      files: <web.File>[file].toJS,
      title: filename,
      text: 'Kubo C\u00e0 Ph\u00ea backup',
    );
    if (!navigator.canShare(data)) return false;
    await navigator.share(data).toDart;
    return true;
  } on Object {
    // No share sheet, or she closed it. Either way, fall back.
    return false;
  }
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
