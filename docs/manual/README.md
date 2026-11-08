# The two manuals

`admin.html` and `barista.html` are the sources; the PDFs beside them are
what the owner is actually sent. The look is the app's own: the Paper
palette, the traced nipa hut from `lib/shared/brand/kubo_roof_path.dart`,
Work Sans for text and Caveat for the section labels, both embedded in
`base.css` so the files render the same anywhere.

To rebuild after an edit:

    node render.js

It needs Playwright and Chromium, and writes both PDFs next to the sources.

Keep them in step with the app. A manual that describes a screen that has
moved is worse than no manual, because she will trust it.
