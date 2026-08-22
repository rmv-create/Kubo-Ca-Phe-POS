import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
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
            _logo(),
            pw.SizedBox(height: 6),
            _centred(settings.businessName, size: 13, bold: true),
            pw.SizedBox(height: 10),
            _header(),
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
            pw.SizedBox(height: 10),
            _centred('Thank you', size: 9),
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

  pw.Widget _header() {
    final DateTime local = order.createdAt.toLocal();
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: <pw.Widget>[
        _centred(order.orderNo, size: 12, bold: true),
        _centred(_formatDateTime(local), size: 8),
        // The name, and only the name. A mobile number printed on a slip of
        // paper that gets left on a table is the customer's, not the shop's,
        // to hand around.
        if (order.customerName != null) ...<pw.Widget>[
          pw.SizedBox(height: 4),
          _centred(order.customerName!, size: 9),
        ],
      ],
    );
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

  List<pw.Widget> _totals() => <pw.Widget>[
    _amountRow('Subtotal', order.subtotal),
    if (order.discountVatExempt.isPositive)
      _amountRow('Less VAT (exempt sale)', -order.discountVatExempt),
    if (order.hasDiscount)
      _amountRow(
        order.discountLabel == null
            ? 'Discount'
            : '${order.discountLabel} '
                  '(${(order.discountRateBp / 100).toStringAsFixed(0)}%)',
        -order.discount,
      ),
    if (order.deliveryFee.isPositive)
      _amountRow('Delivery fee', order.deliveryFee),
    pw.SizedBox(height: 3),
    _amountRow('TOTAL', order.total, bold: true, size: 12),
    if (order.vat.isPositive)
      _amountRow('VAT included (12%)', order.vat, size: 7),
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

  pw.Widget _payment() {
    final PaymentMethod? method = order.paymentMethod;
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: <pw.Widget>[
        _amountRow(method?.label ?? 'Paid', order.total, size: 9),
        if (order.tendered != null)
          _amountRow('Cash received', order.tendered!, size: 8),
        if (order.change != null && order.change!.isPositive)
          _amountRow('Change', order.change!, size: 8),
        if (order.paymentReference != null &&
            order.paymentReference!.isNotEmpty)
          _text('Ref ${order.paymentReference}', size: 7),
      ],
    );
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
