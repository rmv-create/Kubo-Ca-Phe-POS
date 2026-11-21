import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// Makes sure the browser can draw a picture of a receipt, and says whether
/// it can.
///
/// ## Why this exists
///
/// A browser cannot draw a PDF on its own. The preview on the receipt screen
/// is drawn by pdf.js, which is 1.3 MB of JavaScript this app serves from its
/// own build. It is deliberately not loaded at startup — a third of a
/// megabyte in front of the one thing she opens the phone for — so it is
/// fetched after the first frame instead.
///
/// That left a gap nobody was watching: open a receipt before pdf.js has
/// landed, or after a fetch that quietly failed, and the preview had nothing
/// to draw with. It showed white, said nothing, and never tried again. The
/// owner's words for that were "I cannot generate a receipt".
///
/// So the app no longer *hopes* pdf.js is there. It asks for it when it
/// needs it, fetches it itself if the head start did not arrive, waits a
/// sensible length of time, and gives a plain answer either way — which the
/// screen turns into either a receipt or a sentence, never a white rectangle.
Future<bool> readyToDrawReceipts() => _asking ??= _ask();

Future<bool>? _asking;

/// Long enough for a third of a megabyte on a slow phone connection, short
/// enough that she is not left looking at a spinner wondering. A fetch that
/// fails outright answers sooner than this; the timer is only for the one
/// that neither finishes nor fails.
const Duration _patience = Duration(seconds: 12);

Future<bool> _ask() async {
  if (_loaded) return true;

  final Completer<bool> done = Completer<bool>();
  final String base =
      (web.window as JSObject)
          .getProperty<JSString?>('dartPdfJsBaseUrl'.toJS)
          ?.toDart ??
      'pdfjs/';

  final web.HTMLScriptElement script =
      web.document.createElement('script') as web.HTMLScriptElement
        ..src = '${base}pdf.min.js'
        ..async = true;

  void finish(bool success) {
    if (!done.isCompleted) done.complete(success && _loaded);
  }

  // Listened for rather than assigned: the typed `onerror` setter on a
  // script element takes a different shape of handler, and a handler that
  // is quietly never called is how a failed fetch turned into a wait with
  // no end to it.
  script.addEventListener(
    'load',
    (web.Event _) {
      _rememberWorker(base);
      finish(true);
    }.toJS,
  );
  script.addEventListener(
    'error',
    (web.Event _) {
      finish(false);
    }.toJS,
  );

  web.document.head?.append(script);

  // The head start from index.html may still be in flight, in which case the
  // script above is served from the browser's own cache and lands at once.
  // Either way, this is the one place that waits.
  Timer(_patience, () => finish(_loaded));

  final bool ready = await done.future;
  // A failure is not remembered: she may simply have been in a dead spot,
  // and the next try should be a real try.
  if (!ready) _asking = null;
  return ready;
}

/// Whether pdf.js has actually arrived, asked of the browser rather than
/// assumed from whether a script tag loaded.
bool get _loaded => (web.window as JSObject).has('pdfjsLib');

/// pdf.js does its drawing in a worker, which it only finds if it is told
/// where to look.
void _rememberWorker(String base) {
  final JSObject window = web.window as JSObject;
  if (!window.has('pdfjsLib')) return;
  final JSObject lib = window.getProperty<JSObject>('pdfjsLib'.toJS);
  if (!lib.has('GlobalWorkerOptions')) return;
  lib
      .getProperty<JSObject>('GlobalWorkerOptions'.toJS)
      .setProperty('workerSrc'.toJS, '${base}pdf.worker.min.js'.toJS);
}
