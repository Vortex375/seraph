import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Mobile/desktop mirror storage: a real SQLite file in the app support
/// directory, exactly where SettingsController keeps its GetStorage box, so
/// the mirror survives an app restart alongside other local app state.
QueryExecutor openMirrorConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'gallery_mirror.sqlite'));

    // package:sqlite3 (v3+) bundles its own native library, so no extra
    // platform workaround package is needed here - only a writable temp
    // directory for sqlite's spill files.
    sqlite3.tempDirectory = (await getTemporaryDirectory()).path;

    return NativeDatabase.createInBackground(file);
  });
}
