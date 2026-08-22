import 'dart:typed_data';

export 'receipt_sharing_io.dart'
    if (dart.library.js_interop) 'receipt_sharing_web.dart';

/// What happened when a receipt was handed off.
///
/// The difference matters to the person holding the phone: a share sheet has
/// already sent the file, whereas a download has only put it somewhere and
/// still needs attaching to a message.
enum ShareOutcome {
  /// The system share sheet opened. Nothing more to do.
  shared,

  /// The file was saved to the device. It still has to be attached to send.
  saved,

  /// Nothing happened, and the caller should say so.
  failed,
}

/// A receipt ready to be handed off, whatever the platform does with it.
class ReceiptFile {
  const ReceiptFile({
    required this.bytes,
    required this.filename,
    required this.mimeType,
  });

  final Uint8List bytes;
  final String filename;

  /// `application/pdf` or `image/jpeg`. Getting this wrong is why a JPEG can
  /// arrive somewhere as an unopenable PDF.
  final String mimeType;
}
