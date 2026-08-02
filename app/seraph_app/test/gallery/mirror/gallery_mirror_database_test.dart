import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite3;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GalleryMirrorDatabase migrations', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('gallery_mirror_test');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('an app upgrade adding a column survives without losing existing rows',
        () async {
      final file = File(p.join(tempDir.path, 'mirror.sqlite'));

      // Simulate a device that already has a v1 database on disk, written by
      // an earlier app version - before GalleryItems.orientation existed.
      // This models the acceptance criterion directly: "a migration
      // mechanism survives an app upgrade adding a column".
      final v1Raw = sqlite3.sqlite3.open(file.path);
      v1Raw.execute('''
        CREATE TABLE gallery_items (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          origin TEXT NOT NULL DEFAULT 'cloud',
          provider_id TEXT NULL,
          path TEXT NULL,
          seq INTEGER NULL,
          local_relative_path TEXT NULL,
          local_display_name TEXT NULL,
          local_size INTEGER NULL,
          local_date_taken INTEGER NULL,
          captured_at INTEGER NOT NULL,
          captured_at_source TEXT NOT NULL DEFAULT '',
          width INTEGER NOT NULL DEFAULT 0,
          height INTEGER NOT NULL DEFAULT 0,
          size INTEGER NOT NULL DEFAULT 0,
          mime TEXT NOT NULL DEFAULT '',
          unsupported TEXT NOT NULL DEFAULT '',
          metadata_pending INTEGER NOT NULL DEFAULT 0,
          UNIQUE(provider_id, path)
        );
      ''');
      v1Raw.execute('''
        CREATE TABLE sync_cursors (
          source TEXT NOT NULL PRIMARY KEY,
          since INTEGER NOT NULL DEFAULT 0,
          pending_cursor TEXT NULL
        );
      ''');
      v1Raw.execute(
        "INSERT INTO gallery_items (origin, provider_id, path, seq, captured_at) "
        "VALUES ('cloud', 'space-a', '/Photos/a.jpg', 5, 1000);",
      );
      v1Raw.execute(
        "INSERT INTO sync_cursors (source, since) VALUES ('server', 5);",
      );
      v1Raw.execute('PRAGMA user_version = 1;');
      v1Raw.close();

      // Now open with the app's current (v2) database class against the SAME
      // file - this is exactly what happens on app upgrade.
      final db = GalleryMirrorDatabase(NativeDatabase(file));
      addTearDown(db.close);

      // The pre-existing row survived the upgrade...
      final items = await db.select(db.galleryItems).get();
      expect(items, hasLength(1));
      expect(items.single.providerId, 'space-a');
      expect(items.single.path, '/Photos/a.jpg');
      // ...and the new column is there with its default.
      expect(items.single.orientation, 0);

      // The sync cursor also survived - this is what makes a restart not
      // re-fetch the whole gallery after an upgrade.
      final cursor = await (db.select(db.syncCursors)
            ..where((t) => t.source.equals('server')))
          .getSingle();
      expect(cursor.since, 5);

      // The upgraded schema also accepts writes to the new column.
      await db.into(db.galleryItems).insertOnConflictUpdate(
            GalleryItemsCompanion.insert(
              providerId: const Value('space-a'),
              path: const Value('/Photos/b.jpg'),
              capturedAt: 2000,
              orientation: const Value(6),
            ),
          );
      final updated = await (db.select(db.galleryItems)
            ..where((t) => t.path.equals('/Photos/b.jpg')))
          .getSingle();
      expect(updated.orientation, 6);
    });

    test('a fresh install creates the current schema directly via onCreate',
        () async {
      final db = GalleryMirrorDatabase.forTesting();
      addTearDown(db.close);

      // No migration needed; onCreate should produce a fully working schema.
      await db.into(db.galleryItems).insertOnConflictUpdate(
            GalleryItemsCompanion.insert(
              providerId: const Value('space-a'),
              path: const Value('/Photos/a.jpg'),
              capturedAt: 1000,
              orientation: const Value(1),
            ),
          );

      final items = await db.select(db.galleryItems).get();
      expect(items, hasLength(1));
      expect(items.single.orientation, 1);
    });
  });
}
