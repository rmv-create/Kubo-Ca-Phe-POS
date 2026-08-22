import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'receipt_sharing.dart';

/// Hands a receipt over from the browser build.
///
/// ## Why this file exists
///
/// A browser can only give a page a file through a `blob:` URL, and a `blob:`
/// URL is a reference into *that tab's* memory. It is not on the internet.
/// Send one to a customer and they get "cannot open" — not because anything is
/// broken, but because there is nothing at the other end of it. Safari makes
/// this easy to fall into: it will happily show a downloaded PDF in a tab with
/// a `blob:` address that looks exactly like a link.
///
/// So this never leaves a blob URL sitting in the address bar to be copied.
/// It tries the real share sheet first, and only falls back to saving a file.
Future<ShareOutcome> shareReceipt(
  ReceiptFile receipt, {
  String? subject,
}) async {
  final web.File file = web.File(
    <JSUint8Array>[receipt.bytes.toJS].toJS,
    receipt.filename,
    web.FilePropertyBag(type: receipt.mimeType),
  );

  // The Web Share API, where the browser has it — Safari on iOS and iPadOS
  // does. This is the same sheet the installed app would show, so the file
  // goes straight into Messenger or Mail as an attachment.
  //
  // Desktop browsers mostly do not have it, and `canShare` is then not a
  // function at all: calling it throws rather than returning false. Both the
  // check and the call therefore sit inside a catch, because the one outcome
  // that must never happen is the owner tapping PDF and getting nothing.
  try {
    if (_canShareFiles(file, subject ?? receipt.filename)) {
      await web.window.navigator
          .share(
            web.ShareData(
              files: <web.File>[file].toJS,
              title: subject ?? receipt.filename,
            ),
          )
          .toDart;
      return ShareOutcome.shared;
    }
  } on Object {
    // Cancelled, unsupported, or refused. Fall through and save the file.
  }

  return _save(file, receipt.filename);
}

/// Whether this browser can share a file, asked without assuming it can even
/// be asked.
bool _canShareFiles(web.File file, String title) {
  final JSObject navigator = web.window.navigator as JSObject;
  if (!navigator.has('canShare') || !navigator.has('share')) return false;
  return web.window.navigator.canShare(
    web.ShareData(files: <web.File>[file].toJS, title: title),
  );
}

/// Saves the file the ordinary way, with its real name and type.
ShareOutcome _save(web.File file, String filename) {
  final String url = web.URL.createObjectURL(file);
  final web.HTMLAnchorElement link = web.HTMLAnchorElement()
    ..href = url
    ..download = filename;
  web.document.body?.append(link);
  link.click();
  link.remove();
  // Handing the memory back straight away also kills the blob URL, so a copy
  // of it cannot escape and disappoint somebody later.
  web.URL.revokeObjectURL(url);
  return ShareOutcome.saved;
}
