/// Saving an exported shop to a file, and reading one back.
///
/// A browser has no folders, and a phone has no downloads bar; the two
/// platforms need different plumbing for the same two actions, so each has
/// its own implementation behind this one import.
library;

export 'archive_file_io.dart'
    if (dart.library.js_interop) 'archive_file_web.dart';
