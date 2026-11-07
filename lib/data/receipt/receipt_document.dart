import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:meta/meta.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/money/money.dart';
import '../../domain/entities/business_settings.dart';
import '../../domain/entities/order_draft.dart';
import '../../domain/entities/reporting.dart';
import '../../shared/brand/kubo_roof_path.dart';

/// Builds the customer's receipt as a PDF.
///
/// The page is 80mm wide with an open-ended height, which is the shape of a
/// thermal roll. It prints correctly on a phone's AirPrint printer today and
/// is the right shape for a receipt printer when one arrives, rather than an
/// A4 page with a receipt stranded in the corner of it.
class ReceiptDocument {
  const ReceiptDocument({
    required this.order,
    required this.settings,
    this.footerImage,
  });

  final OrderRecord order;
  final BusinessSettings settings;

  /// The owner's own image — a QR to her socials or a review page — decoded
  /// from settings. Null when she has not uploaded one.
  final Uint8List? footerImage;

  /// Roll width. 80mm is the common thermal size; 72mm of it is printable.
  static const double _widthMm = 80;

  Future<Uint8List> build() async {
    // The PDF standard fonts have no ₱ — every amount would print as an empty
    // box. These are a subset of Work Sans carrying the peso sign and the
    // Vietnamese vowels in "Cà Phê"; see assets/fonts/README.md.
    final pw.ThemeData theme = pw.ThemeData.withFont(
      base: await _font('assets/fonts/ReceiptSans-Regular.ttf'),
      bold: await _font('assets/fonts/ReceiptSans-Bold.ttf'),
    );

    final pw.Document doc = pw.Document(
      title: 'Receipt ${order.orderNo}',
      author: settings.businessName,
      theme: theme,
    );

    doc.addPage(
      pw.Page(
        pageFormat: const PdfPageFormat(
          _widthMm * PdfPageFormat.mm,
          double.infinity,
          marginAll: 5 * PdfPageFormat.mm,
        ),
        build: (pw.Context context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          mainAxisSize: pw.MainAxisSize.min,
          children: <pw.Widget>[
            // ── centred: who this is from, and which order ──
            _logo(),
            pw.SizedBox(height: 6),
            ..._businessName(),
            ..._contact(),
            pw.SizedBox(height: 10),
            _centred(order.orderNo, size: 12, bold: true),
            _centred(_formatDateTime(order.createdAt.toLocal()), size: 8),

            // ── left from here down: everything about the order ──
            if (order.customerName != null) ...<pw.Widget>[
              pw.SizedBox(height: 8),
              _text('Customer Name: ${order.customerName}', size: 9),
            ],
            _rule(),
            ..._items(),
            _rule(),
            ..._totals(),
            pw.SizedBox(height: 8),
            _payment(),
            if (order.isVoided) ...<pw.Widget>[
              pw.SizedBox(height: 8),
              _centred('VOIDED', size: 12, bold: true),
              if (order.voidReason != null)
                _centred(order.voidReason!, size: 8),
            ],
            ..._closing(),
            if (footerImage != null) ...<pw.Widget>[
              pw.SizedBox(height: 12),
              pw.Center(
                child: pw.Image(
                  pw.MemoryImage(footerImage!),
                  width: 40 * PdfPageFormat.mm,
                  fit: pw.BoxFit.contain,
                ),
              ),
            ],
            pw.SizedBox(height: 6),
          ],
        ),
      ),
    );

    return doc.save();
  }

  /// Loads a bundled font. Cached, because a busy morning prints a lot of
  /// receipts and the bytes never change.
  static final Map<String, pw.Font> _fonts = <String, pw.Font>{};

  static Future<pw.Font> _font(String asset) async =>
      _fonts[asset] ??= pw.Font.ttf(await rootBundle.load(asset));

  /// The nipa hut, drawn from the same outline the app uses on screen.
  pw.Widget _logo() => pw.Center(
    child: pw.SizedBox(
      width: 30 * PdfPageFormat.mm,
      height: 30 * PdfPageFormat.mm * (kuboRoofHeight / kuboRoofWidth),
      child: pw.CustomPaint(
        painter: (PdfGraphics canvas, PdfPoint size) {
          canvas
            ..saveContext()
            ..setFillColor(PdfColors.black);
          _tracePath(canvas, kuboRoofPathData, size);
          canvas
            ..fillPath(evenOdd: true)
            ..restoreContext();
        },
      ),
    ),
  );

  /// The shop's name, stacked the way the logo stacks it.
  ///
  /// "Kubo" over "Cà Phê", because that is how the mark above it reads. Any
  /// other business name is left on one line rather than split at a space it
  /// was never meant to break at.
  List<pw.Widget> _businessName() {
    const String kubo = 'Kubo Cà Phê';
    if (settings.businessName.trim() != kubo) {
      return <pw.Widget>[_centred(settings.businessName, size: 13, bold: true)];
    }
    return <pw.Widget>[
      _centred('Kubo', size: 15, bold: true),
      _centred('Cà Phê', size: 12, bold: true),
    ];
  }

  /// The drinks, itemised.
  ///
  /// The price beside a drink is the drink's own; anything a modification
  /// added is its own line underneath with its own charge. Every figure in the
  /// right-hand column adds up to the subtotal, so a customer can check the
  /// arithmetic rather than take the total on trust.
  List<pw.Widget> _items() => <pw.Widget>[
    for (final OrderLineRecord line in order.lines) ...<pw.Widget>[
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: <pw.Widget>[
          pw.SizedBox(width: 18, child: _text('${line.quantity}x', size: 9)),
          pw.Expanded(child: _text(line.title, size: 9, bold: true)),
          // A long name — "Small Sea Salt Matcha Oat Latte" — runs the whole
          // width, and without this the price is printed against it.
          pw.SizedBox(width: 6),
          _text(line.baseTotal.format(), size: 9),
        ],
      ),
      // On a line of more than one, the price above is for all of them, so
      // the price of a single drink is spelled out too.
      if (line.quantity > 1)
        pw.Padding(
          padding: const pw.EdgeInsets.only(left: 18),
          child: _text('${line.unitBasePrice.format()} each', size: 7),
        ),

      // Every modification, spelled out — "less sweet" and "extra shot" are
      // the whole reason a customer reads a receipt — and the ones that cost
      // something say so.
      for (final OrderLineOption option in line.options)
        pw.Padding(
          padding: const pw.EdgeInsets.only(left: 18, top: 1),
          child: pw.Row(
            children: <pw.Widget>[
              pw.Expanded(child: _text('· ${option.name}', size: 8)),
              if (option.isCharged)
                _text('+${option.totalFor(line.quantity).format()}', size: 8),
            ],
          ),
        ),
      pw.SizedBox(height: 5),
    ],
  ];

  /// Subtotal, what came off, what went on, and what was owed.
  ///
  /// Only lines that happened are printed. A walk-in coffee has no discount
  /// and no delivery, and a receipt that lists them at ₱0.00 is asking the
  /// customer to read two lines that say nothing.
  ///
  /// Worked out as data rather than straight into widgets, so a test can
  /// assert exactly which lines a given order produces. "Only if there is
  /// one" is the sort of rule that quietly stops being true.
  static List<ReceiptLine> totalLines(OrderRecord order) => <ReceiptLine>[
    ReceiptLine('Subtotal', order.subtotal),
    // Only ever present on a VAT-registered shop's exempt sale, where the
    // figures would not otherwise add up — and where the BIR expects to see
    // exempt sales stated.
    if (order.discountVatExempt.isPositive)
      ReceiptLine('Less VAT (exempt sale)', -order.discountVatExempt),
    if (order.hasDiscount)
      ReceiptLine(
        order.discountLabel == null
            ? 'Discount'
            : '${order.discountLabel} '
                  '(${(order.discountRateBp / 100).toStringAsFixed(0)}%)',
        -order.discount,
      ),
    // Always printed, even at zero: she asked for the line to be there, and
    // a customer who was not charged for delivery can see that they were not.
    // The discount is the opposite — no discount, no line.
    ReceiptLine('Delivery fee', order.deliveryFee),
    ReceiptLine('Total', order.total, emphasised: true),
    if (order.vat.isPositive) ReceiptLine('VAT included (12%)', order.vat),
  ];

  /// How it was paid, and the one thing that follows from that.
  ///
  /// Cash has change; anything settled through a phone has a reference, and
  /// only when one was actually typed in. Neither appears on the other.
  static List<ReceiptLine> paymentLines(OrderRecord order) {
    // An order she sent out before the money arrived says so, plainly, and
    // says what is owed. Nothing invents a payment method for it.
    if (order.isUnpaid) {
      return <ReceiptLine>[
        const ReceiptLine('NOT YET PAID', null),
        ReceiptLine('Amount due', order.total, emphasised: true),
      ];
    }
    final PaymentMethod? method = order.paymentMethod;
    final String? reference = order.paymentReference;
    return <ReceiptLine>[
      ReceiptLine('${method?.label ?? 'Paid'} payment', order.total),
      if (order.tendered != null) ...<ReceiptLine>[
        ReceiptLine('Received', order.tendered!),
        ReceiptLine('Change', order.change ?? Money.zero),
      ],
      if (reference != null && reference.isNotEmpty)
        ReceiptLine(
          '${method?.label ?? 'Payment'} reference: $reference',
          null,
        ),
    ];
  }

  List<pw.Widget> _totals() => <pw.Widget>[
    for (final ReceiptLine line in totalLines(order))
      if (line.emphasised) ...<pw.Widget>[
        pw.SizedBox(height: 3),
        _amountRow(line.label, line.amount!, bold: true, size: 12),
      ] else
        _amountRow(
          line.label,
          line.amount!,
          size: line.label.startsWith('VAT') ? 7 : 9,
        ),
    // RA 9994 and RA 10754 make the shop record who claimed the discount, so
    // the receipt carries it too.
    if (order.discountBeneficiaryName != null ||
        order.discountBeneficiaryIdNo != null) ...<pw.Widget>[
      pw.SizedBox(height: 4),
      _text(
        '${order.discountLabel ?? 'Discount'}: '
        '${order.discountBeneficiaryName ?? '—'}',
        size: 7,
      ),
      _text('ID: ${order.discountBeneficiaryIdNo ?? '—'}', size: 7),
    ],
  ];

  pw.Widget _payment() => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: <pw.Widget>[
      for (final ReceiptLine line in paymentLines(order))
        if (line.amount == null)
          if (order.isUnpaid)
            _centred(line.label, size: 11, bold: true)
          else
            _text(line.label, size: 8)
        else
          _amountRow(
            line.label,
            line.amount!,
            size: line.label.endsWith('payment') ? 9 : 8,
          ),
    ],
  );

  /// The foot of the receipt: the code on the left, her words beside it.
  ///
  /// Laid out the way she drew it. The QR is *drawn* from the link in
  /// settings rather than pasted in as a picture, so changing where it points
  /// is typing, and the code stays sharp at any print size.
  List<pw.Widget> _closing() {
    final String data = settings.receiptQrData.trim();
    final String note = order.note?.trim() ?? '';
    final String thanks = settings.receiptThankYou.trim();
    if (data.isEmpty && note.isEmpty && thanks.isEmpty) {
      return const <pw.Widget>[];
    }

    // With no code there is nothing to sit beside, so the words take the full
    // width and centre themselves instead of hugging a missing square.
    if (data.isEmpty) {
      return <pw.Widget>[
        pw.SizedBox(height: 10),
        if (note.isNotEmpty) _centred('Note: $note', size: 8),
        if (note.isNotEmpty && thanks.isNotEmpty) pw.SizedBox(height: 6),
        if (thanks.isNotEmpty) _centred(thanks, size: 11, bold: true),
      ];
    }

    final List<pw.Widget> words = <pw.Widget>[
      if (note.isNotEmpty) _text('Note: $note', size: 8),
      if (note.isNotEmpty && thanks.isNotEmpty) pw.SizedBox(height: 6),
      if (thanks.isNotEmpty) _text(thanks, size: 11, bold: true),
    ];

    return <pw.Widget>[
      pw.SizedBox(height: 12),
      pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: <pw.Widget>[
          pw.BarcodeWidget(
            barcode: pw.Barcode.qrCode(),
            data: data,
            width: 24 * PdfPageFormat.mm,
            height: 24 * PdfPageFormat.mm,
            drawText: false,
          ),
          if (words.isNotEmpty) ...<pw.Widget>[
            pw.SizedBox(width: 8),
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                mainAxisAlignment: pw.MainAxisAlignment.center,
                children: words,
              ),
            ),
          ],
        ],
      ),
    ];
  }

  /// Where to find her, directly under the shop's name — where she put it on
  /// the receipt she marked up.
  ///
  /// Facebook and Instagram share a line, as she wrote them. Each line is
  /// printed only if she has filled it in: a receipt with an empty "Address:"
  /// on it looks like a mistake.
  List<pw.Widget> _contact() {
    final String facebook = settings.receiptFacebook.trim();
    final String instagram = settings.receiptInstagram.trim();
    final String social = <String>[
      if (facebook.isNotEmpty) 'Facebook: $facebook',
      if (instagram.isNotEmpty) 'Instagram: $instagram',
    ].join(' | ');

    final List<String> lines = <String>[
      if (settings.receiptAddress.trim().isNotEmpty)
        settings.receiptAddress.trim(),
      if (social.isNotEmpty) social,
      if (settings.receiptPhone.trim().isNotEmpty)
        'Phone: ${settings.receiptPhone.trim()}',
    ];
    if (lines.isEmpty) return const <pw.Widget>[];
    return <pw.Widget>[
      pw.SizedBox(height: 5),
      for (final String line in lines) _centred(line, size: 7.5),
    ];
  }

  pw.Widget _amountRow(
    String label,
    Money amount, {
    bool bold = false,
    double size = 9,
  }) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 1),
    child: pw.Row(
      children: <pw.Widget>[
        pw.Expanded(
          child: _text(label, size: size, bold: bold),
        ),
        _text(amount.format(), size: size, bold: bold),
      ],
    ),
  );

  pw.Widget _rule() => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 5),
    child: pw.Divider(height: 0.6, thickness: 0.6, color: PdfColors.grey600),
  );

  pw.Widget _text(String value, {double size = 9, bool bold = false}) =>
      pw.Text(
        value,
        style: pw.TextStyle(
          fontSize: size,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      );

  /// `15 Mar 2026, 10:30 AM` — unambiguous, and the way a receipt reads.
  static String _formatDateTime(DateTime local) =>
      DateFormat('d MMM y, h:mm a').format(local);

  pw.Widget _centred(String value, {double size = 9, bool bold = false}) =>
      pw.Center(
        child: pw.Text(
          value,
          textAlign: pw.TextAlign.center,
          style: pw.TextStyle(
            fontSize: size,
            fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
          ),
        ),
      );
}

/// One printed line: a label, and an amount unless it is a note.
@immutable
class ReceiptLine {
  const ReceiptLine(this.label, this.amount, {this.emphasised = false});

  final String label;

  /// Null for a line that is words only, like a payment reference.
  final Money? amount;

  /// The total. Printed larger, because it is the number people look for.
  final bool emphasised;

  @override
  String toString() => amount == null ? label : '$label ${amount!.format()}';
}

/// Decodes the footer image the owner saved into settings.
///
/// Returns null rather than throwing on anything malformed: a corrupted
/// setting must never stop a customer getting a receipt.
Uint8List? decodeFooterImage(String? base64Png) {
  if (base64Png == null || base64Png.isEmpty) return null;
  try {
    return base64Decode(base64Png);
  } on FormatException {
    return null;
  }
}

/// Replays the roof outline onto a PDF canvas.
///
/// The same narrow vocabulary the on-screen parser accepts — absolute M, L, C
/// and Z — so the mark on a receipt cannot drift from the mark in the header.
void _tracePath(PdfGraphics canvas, String data, PdfPoint into) {
  final double sx = into.x / kuboRoofWidth;
  final double sy = into.y / kuboRoofHeight;

  // The outline is on a grid whose y runs down the page; PDF's runs up. The
  // flip happens here, per point, rather than through a canvas transform —
  // one less piece of state to leave switched on by accident.
  double x(double v) => v * sx;
  double y(double v) => into.y - v * sy;

  int i = 0;

  double number() {
    while (i < data.length && (data[i] == ' ' || data[i] == ',')) {
      i++;
    }
    final int start = i;
    if (i < data.length && (data[i] == '-' || data[i] == '+')) i++;
    const int zero = 0x30, nine = 0x39, dot = 0x2e;
    while (i < data.length) {
      final int c = data.codeUnitAt(i);
      if ((c >= zero && c <= nine) || c == dot) {
        i++;
      } else {
        break;
      }
    }
    return double.parse(data.substring(start, i));
  }

  while (i < data.length) {
    switch (data[i++]) {
      case 'M':
        canvas.moveTo(x(number()), y(number()));
      case 'L':
        canvas.lineTo(x(number()), y(number()));
      case 'C':
        canvas.curveTo(
          x(number()),
          y(number()),
          x(number()),
          y(number()),
          x(number()),
          y(number()),
        );
      case 'Z':
        canvas.closePath();
    }
  }
}
