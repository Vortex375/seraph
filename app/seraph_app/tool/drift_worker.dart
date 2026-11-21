import 'package:drift/wasm.dart';

/// Source of `web/drift_worker.js`, the web gallery mirror's database worker.
/// Rebuild it whenever pubspec.lock moves `drift`, so the worker and the app
/// speak the same drift version:
/// `dart compile js -O4 tool/drift_worker.dart -o web/drift_worker.js`
void main() => WasmDatabase.workerMainForOpen();
