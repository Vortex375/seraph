import 'package:drift/drift.dart';

/// Fallback for a platform that has neither `dart:ffi` nor `dart:js_interop`.
/// No target the app currently ships to selects this file; it exists so the
/// conditional import in `connection.dart` always has a default that keeps
/// the code analyzable.
QueryExecutor openMirrorConnection() {
  throw UnsupportedError(
    'The gallery mirror has no database implementation on this platform.',
  );
}
