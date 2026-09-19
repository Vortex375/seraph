import 'package:drift/drift.dart';

import 'unsupported.dart'
    if (dart.library.ffi) 'native.dart'
    if (dart.library.js_interop) 'web.dart' as impl;

/// Opens the mirror's database connection for whichever platform the app was
/// compiled for.
///
/// This exists as a conditional-import seam because the app ships to native
/// platforms AND to the web (the `Dockerfile` builds `flutter build web` and
/// serves the result as Seraph's web UI). `package:drift/native.dart` pulls in
/// `dart:ffi`, which does not exist on the web, so importing it unconditionally
/// fails the WEB BUILD - not just at runtime. Only one of the three
/// implementations below is ever compiled into a given build:
///
/// - `native.dart` (`dart.library.ffi`): mobile and desktop, backed by a real
///   file in the app support directory via `NativeDatabase.createInBackground`.
/// - `web.dart` (`dart.library.js_interop`): the browser, backed by
///   `WasmDatabase` over OPFS/IndexedDB, using `web/sqlite3.wasm` and
///   `web/drift_worker.js`.
/// - `unsupported.dart`: the fallback that only exists to keep this file
///   analyzable on a platform with neither library; it throws if called.
QueryExecutor openMirrorConnection() => impl.openMirrorConnection();
