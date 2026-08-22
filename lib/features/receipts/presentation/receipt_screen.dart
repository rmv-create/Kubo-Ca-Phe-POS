import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:printing/printing.dart';

import '../../../app/providers.dart';
import '../../../app/theme/kubo_tokens.dart';
import '../../../core/errors/app_exception.dart';
import '../../../data/receipt/receipt_document.dart';
import '../../../domain/entities/business_settings.dart';
import '../../../domain/entities/reporting.dart';
import '../../../shared/widgets/async_view.dart';
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
                  // The app's own buttons sit below, where a thumb reaches.
                  actions: const <PdfPreviewAction>[],
                  pdfFileName: 'Receipt ${record.orderNo}.pdf',
                ),
              ),
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

  Future<void> _sharePdf(OrderRecord record) async {
    await Printing.sharePdf(
      bytes: await _pdf(record),
      filename: 'Receipt ${record.orderNo}.pdf',
    );
  }

  /// The same receipt as a picture, for sending over Messenger or Viber where
  /// a PDF is awkward to open.
  Future<void> _shareJpeg(OrderRecord record) async {
    final Uint8List pdf = await _pdf(record);
    final PdfRaster page = await Printing.raster(
      pdf,
      // Roughly 200dpi across an 80mm roll: sharp on a phone screen, and small
      // enough to send over a slow connection.
      pages: <int>[0],
      dpi: 200,
    ).first;

    final img.Image image = img.Image.fromBytes(
      width: page.width,
      height: page.height,
      bytes: (await page.toPng()).buffer,
      numChannels: 4,
    );
    // A receipt is black on white, so JPEG's artefacts are invisible and the
    // file is a fraction of the PNG. Flattened onto white because JPEG has no
    // transparency and would otherwise render the paper black.
    final img.Image flattened = img.Image.from(image)..convert(numChannels: 3);

    await Printing.sharePdf(
      bytes: Uint8List.fromList(img.encodeJpg(flattened, quality: 90)),
      filename: 'Receipt ${record.orderNo}.jpg',
    );
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await action();
    } on AppException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
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
    required this.onName,
  });

  final bool busy;
  final bool hasCustomer;
  final VoidCallback onPrint;
  final VoidCallback onPdf;
  final VoidCallback onJpeg;
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
      FilledButton.icon(
        onPressed: busy ? null : onPrint,
        icon: const Icon(Icons.print_outlined),
        label: const Text('PRINT'),
      ),
    ],
  );
}
