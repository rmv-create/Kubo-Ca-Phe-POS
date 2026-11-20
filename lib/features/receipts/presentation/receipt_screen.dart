import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:printing/printing.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/errors/app_exception.dart';
import '../../../data/receipt/receipt_document.dart';
import '../../../data/receipt/receipt_sharing.dart';
import '../../../domain/entities/business_settings.dart';
import '../../../domain/entities/reporting.dart';
import '../../../shared/widgets/async_view.dart';
import '../../../shared/widgets/section_header.dart';
import 'name_this_order_sheet.dart';

/// The receipt for one completed order: preview, print, and save.
///
/// Printing goes through the system print dialog, which on an iPhone means
/// AirPrint — any printer on the same Wi-Fi, and "Save to Files" as a PDF.
/// A Bluetooth thermal printer speaks a different language (ESC/POS) and would
/// need its own driver; the page it prints is already the right shape for one.
class ReceiptScreen extends ConsumerStatefulWidget {
  const ReceiptScreen({required this.orderId, super.key});

  final int orderId;

  @override
  ConsumerState<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends ConsumerState<ReceiptScreen> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final AsyncValue<OrderRecord?> order = ref.watch(
      orderByIdProvider(widget.orderId),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Receipt')),
      body: AsyncView<OrderRecord?>(
        value: order,
        builder: (BuildContext context, OrderRecord? record) {
          if (record == null) {
            return const Center(child: Text('That order is no longer here.'));
          }
          return Column(
            children: <Widget>[
              Expanded(
                child: PdfPreview(
                  build: (_) => _pdf(record),
                  canChangePageFormat: false,
                  canChangeOrientation: false,
                  canDebug: false,
                  // The package's own toolbar is switched off, not emptied.
                  // Its print and share buttons hand back a `blob:` URL that
                  // works nowhere but this tab, which is exactly the trap this
                  // screen exists to avoid. The app's own buttons sit below,
                  // where a thumb reaches.
                  useActions: false,
                  pdfFileName: 'Receipt ${record.orderNo}.pdf',
                ),
              ),
              if (kIsWeb) const _WebSendingNote(),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(KuboSpacing.lg),
                  child: _Actions(
                    busy: _busy,
                    hasCustomer: record.customerName != null,
                    onPrint: () => _guard(() => _print(record)),
                    onPdf: () => _guard(() => _sharePdf(record)),
                    onJpeg: () => _guard(() => _shareJpeg(record)),
                    onSave: () => _saveToPhone(record),
                    onName: () => NameThisOrderSheet.show(context, record),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<Uint8List> _pdf(OrderRecord record) async {
    final BusinessSettings settings = ref.read(settingsControllerProvider);
    final String? footer = await ref
        .read(settingsRepositoryProvider)
        .readRaw(SettingKeys.receiptFooterImage);
    return ReceiptDocument(
      order: record,
      settings: settings,
      footerImage: decodeFooterImage(footer),
    ).build();
  }

  Future<void> _print(OrderRecord record) async {
    await Printing.layoutPdf(
      onLayout: (_) => _pdf(record),
      name: 'Receipt ${record.orderNo}',
    );
  }

  Future<void> _sharePdf(OrderRecord record, {bool share = true}) async {
    await _hand(
      ReceiptFile(
        bytes: await _pdf(record),
        filename: 'Receipt ${record.orderNo}.pdf',
        mimeType: 'application/pdf',
      ),
      record,
      share: share,
    );
  }

  /// The same receipt as a picture, for sending over Messenger or Viber where
  /// a PDF is awkward to open.
  Future<void> _shareJpeg(OrderRecord record, {bool share = true}) async {
    final Uint8List pdf = await _pdf(record);
    final PdfRaster page = await Printing.raster(
      pdf,
      // Roughly 200dpi across an 80mm roll: sharp on a phone screen, and small
      // enough to send over a slow connection.
      pages: <int>[0],
      dpi: 200,
    ).first;

    // `pixels` is raw RGBA. `toPng()` would hand back an encoded PNG, which
    // this constructor would read as pixel data and turn into noise.
    final img.Image image = img.Image.fromBytes(
      width: page.width,
      height: page.height,
      bytes: page.pixels.buffer,
      numChannels: 4,
    );
    // A receipt is black on white, so JPEG's artefacts are invisible and the
    // file is a fraction of the PNG. Flattened onto white because JPEG has no
    // transparency and would otherwise render the paper black. `convert`
    // returns a new image rather than changing this one.
    final img.Image flattened = image.convert(numChannels: 3);

    await _hand(
      ReceiptFile(
        bytes: Uint8List.fromList(img.encodeJpg(flattened, quality: 90)),
        filename: 'Receipt ${record.orderNo}.jpg',
        // Not application/pdf. A JPEG mislabelled as a PDF arrives as a file
        // nothing will open, which is a nasty thing to send a customer.
        mimeType: 'image/jpeg',
      ),
      record,
      share: share,
    );
  }

  /// Puts the receipt in the phone's own Downloads folder.
  ///
  /// The share sheet is how a receipt reaches a customer, and on Android it
  /// offers Photos and messaging apps and no file manager — so a receipt
  /// sent that way is in her photo roll or nowhere. This skips it.
  ///
  /// A browser cannot write into the Android gallery itself; nothing on the
  /// web can. What it can do is download, and Downloads is where a gallery
  /// app looks and where Files opens, which is what she was asking for.
  Future<void> _saveToPhone(OrderRecord record) async {
    final bool? asPicture = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const SectionHeader('Save to this phone'),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Picture'),
              subtitle: const Text('A JPEG, into Downloads'),
              onTap: () => Navigator.of(context).pop(true),
            ),
            ListTile(
              leading: const Icon(Icons.picture_as_pdf_outlined),
              title: const Text('PDF'),
              subtitle: const Text('Into Downloads'),
              onTap: () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      ),
    );
    if (asPicture == null) return;

    await _guard(
      () => asPicture
          ? _shareJpeg(record, share: false)
          : _sharePdf(record, share: false),
    );
  }

  /// Hands the file to the phone, and says plainly what happened.
  ///
  /// On a device with a share sheet the file is already on its way. In a
  /// browser without one it has only been saved, and the difference matters:
  /// the address bar will be showing a `blob:` URL that exists nowhere but
  /// this tab. Sending that to a customer gets "cannot open", so the app says
  /// so rather than letting her find out from them.
  Future<void> _hand(
    ReceiptFile file,
    OrderRecord record, {
    bool share = true,
  }) async {
    final ShareOutcome outcome = await shareReceipt(
      file,
      subject: 'Receipt ${record.orderNo}',
      shareFirst: share,
    );
    if (!mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    switch (outcome) {
      case ShareOutcome.shared:
        break;
      case ShareOutcome.saved:
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            SnackBar(
              duration: const Duration(seconds: 8),
              content: Text(
                'Saved as ${file.filename}. Attach that file to your '
                'message — do not copy the web address, it only works on '
                'this device.',
              ),
            ),
          );
      case ShareOutcome.failed:
        messenger
          ..clearSnackBars()
          ..showSnackBar(
            const SnackBar(
              content: Text('This device could not share the receipt.'),
            ),
          );
    }
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await action();
    } on AppException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } on Object catch (error) {
      // A receipt failing must never be silent. Anything a platform throws —
      // a browser without a share sheet, a printer that vanished — says so
      // here rather than looking like a dead button.
      messenger.showSnackBar(
        SnackBar(content: Text('The receipt could not be sent: $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.busy,
    required this.hasCustomer,
    required this.onPrint,
    required this.onPdf,
    required this.onJpeg,
    required this.onSave,
    required this.onName,
  });

  final bool busy;
  final bool hasCustomer;
  final VoidCallback onPrint;
  final VoidCallback onPdf;
  final VoidCallback onJpeg;
  final VoidCallback onSave;
  final VoidCallback onName;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      if (!hasCustomer)
        Padding(
          padding: const EdgeInsets.only(bottom: KuboSpacing.sm),
          child: OutlinedButton.icon(
            onPressed: busy ? null : onName,
            icon: const Icon(Icons.person_add_alt),
            label: const Text('ADD THE CUSTOMER'),
          ),
        ),
      Row(
        children: <Widget>[
          Expanded(
            child: OutlinedButton.icon(
              onPressed: busy ? null : onPdf,
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('PDF'),
            ),
          ),
          const SizedBox(width: KuboSpacing.sm),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: busy ? null : onJpeg,
              icon: const Icon(Icons.image_outlined),
              label: const Text('JPEG'),
            ),
          ),
        ],
      ),
      const SizedBox(height: KuboSpacing.sm),
      // PDF and JPEG go through the phone's share sheet, which on Android
      // offers Photos and messaging apps and no file manager — so a receipt
      // sent that way lands in her photo roll and nowhere she can find it
      // again. This puts the file in Downloads instead, where a file keeps.
      OutlinedButton.icon(
        onPressed: busy ? null : onSave,
        icon: const Icon(Icons.download_outlined),
        label: const Text('SAVE TO THIS PHONE'),
      ),
      const SizedBox(height: KuboSpacing.sm),
      FilledButton.icon(
        onPressed: busy ? null : onPrint,
        icon: const Icon(Icons.print_outlined),
        label: const Text('PRINT'),
      ),
    ],
  );
}

/// Only shown in the browser build, because only the browser build can leave
/// her holding a `blob:` address that looks like a link and is not one.
class _WebSendingNote extends StatelessWidget {
  const _WebSendingNote();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.surfaceContainer,
      padding: const EdgeInsets.fromLTRB(
        KuboSpacing.lg,
        KuboSpacing.md,
        KuboSpacing.lg,
        KuboSpacing.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            Icons.info_outline,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: KuboSpacing.sm),
          Expanded(
            child: Text(
              'Send the file itself — attach the saved PDF or JPEG to your '
              'message. A web address starting "blob:" only works on this '
              'device, so a customer sent one cannot open it.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
