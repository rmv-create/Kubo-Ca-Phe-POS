import 'package:share_plus/share_plus.dart';

import 'receipt_sharing.dart';

/// On a phone or tablet the system share sheet is exactly the right thing:
/// Messenger, Viber, Mail, AirDrop and "Save to Files" all appear in it, and
/// each receives the file itself rather than a reference to it.
Future<ShareOutcome> shareReceipt(
  ReceiptFile receipt, {
  String? subject,
}) async {
  final ShareResult result = await Share.shareXFiles(
    <XFile>[
      XFile.fromData(
        receipt.bytes,
        name: receipt.filename,
        mimeType: receipt.mimeType,
      ),
    ],
    subject: subject,
    fileNameOverrides: <String>[receipt.filename],
  );
  return result.status == ShareResultStatus.unavailable
      ? ShareOutcome.failed
      : ShareOutcome.shared;
}
