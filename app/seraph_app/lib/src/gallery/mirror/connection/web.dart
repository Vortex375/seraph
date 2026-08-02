import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

/// Browser mirror storage: sqlite3 compiled to WebAssembly, persisted through
/// the best storage API the browser offers (drift probes for OPFS first, then
/// IndexedDB, falling back to memory).
///
/// Both assets this needs are committed under `web/` and are therefore copied
/// into the build output by `flutter build web`, which is what the Dockerfile
/// serves:
/// - `sqlite3.wasm` - from the sqlite3.dart release matching the pinned
///   `sqlite3` package version (3.5.0).
/// - `drift_worker.js` - the prebuilt worker shipped inside the drift package.
///
/// The URIs are RELATIVE so they resolve against whatever base href the app is
/// served under; the Dockerfile builds with `--base-href=/app/`, so hardcoding
/// an absolute path here would break in the shipped image.
QueryExecutor openMirrorConnection() {
  return LazyDatabase(() async {
    final result = await WasmDatabase.open(
      databaseName: 'gallery_mirror',
      sqlite3Uri: Uri.parse('sqlite3.wasm'),
      driftWorkerUri: Uri.parse('drift_worker.js'),
    );

    return result.resolvedExecutor;
  });
}
