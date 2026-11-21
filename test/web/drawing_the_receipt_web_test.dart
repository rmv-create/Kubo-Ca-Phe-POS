@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:kubo_pos/data/receipt/drawing_the_receipt.dart';
import 'package:web/web.dart' as web;

/// The receipt preview, asked the one question that matters in a browser.
///
/// She could not generate a receipt: the screen stayed white. The picture of
/// a receipt is drawn by pdf.js, which is fetched separately and can be slow
/// or absent — and the screen had no answer for that, so it showed nothing
/// and said nothing, for ever.
///
/// What this pins down is not that pdf.js works. It is that the app always
/// gets an *answer* about whether it can draw, so the screen can show either
/// a receipt or a sentence.
void main() {
  test(
    'says no, rather than waiting for ever, when pdf.js is not there',
    () async {
      // Nothing serves pdfjs/pdf.min.js here, so this is a phone that cannot
      // fetch it — the case that used to show white.
      final Stopwatch w = Stopwatch()..start();
      final bool can = await readyToDrawReceipts();

      expect(can, isFalse, reason: 'there is no pdf.js in this page');
      // Quickly, and not by running down a timer: a fetch that fails says so
      // at once, and the screen can offer her the buttons that still work.
      // When the script's error was listened for the wrong way this took the
      // full twelve seconds, which she would have read as white too.
      expect(
        w.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason: 'it must answer, not hang: a hang is the white screen',
      );
    },
  );

  test('says yes when pdf.js is already in the page', () async {
    // What a warm launch looks like: index.html fetched it after the first
    // frame and it is sitting there.
    (web.window as JSObject).setProperty('pdfjsLib'.toJS, JSObject());

    expect(await readyToDrawReceipts(), isTrue);
  });
}
