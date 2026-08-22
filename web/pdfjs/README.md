# pdf.js, vendored

`pdf.min.js` and `pdf.worker.min.js` are Mozilla's **pdf.js** 3.11.174, under
the Apache 2.0 licence in `LICENSE`.

The `printing` package needs pdf.js to show a receipt preview in a browser, and
by default it fetches it from a CDN the first time a receipt is opened. That
would break the one promise this app makes — that it works without internet —
and on a bad connection it fails silently, leaving the preview blank with
"Unable to display the document".

So the files live here and `web/index.html` points the package at them with
`window.dartPdfJsBaseUrl`. Nothing is fetched at run time.

Only the browser build uses these. On iOS the receipt is rendered by the
system, and none of this is compiled in.
