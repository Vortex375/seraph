import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
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

    test(
        'an app upgrade from v3 creates the ticket-30 indexes and the Local '
        'Folder selection table without losing existing rows or the sync '
        'cursor', () async {
      final file = File(p.join(tempDir.path, 'mirror.sqlite'));

      // A v3 database - GalleryItems.orientation and CachedThumbnails both
      // already exist, but neither ticket 30's indexes (v4) nor ticket 29's
      // Local Folder selection table (v5) do. One fixture covers both steps
      // deliberately: the two tickets were written in parallel, each as v4,
      // and a v3 device has to come out of the ladder with BOTH - which is
      // exactly what a test per branch would each have missed.
      final v3Raw = sqlite3.sqlite3.open(file.path);
      v3Raw.execute('''
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
          orientation INTEGER NOT NULL DEFAULT 0,
          size INTEGER NOT NULL DEFAULT 0,
          mime TEXT NOT NULL DEFAULT '',
          unsupported TEXT NOT NULL DEFAULT '',
          metadata_pending INTEGER NOT NULL DEFAULT 0,
          UNIQUE(provider_id, path)
        );
      ''');
      v3Raw.execute('''
        CREATE TABLE sync_cursors (
          source TEXT NOT NULL PRIMARY KEY,
          since INTEGER NOT NULL DEFAULT 0,
          pending_cursor TEXT NULL
        );
      ''');
      v3Raw.execute('''
        CREATE TABLE cached_thumbnails (
          provider_id TEXT NOT NULL,
          path TEXT NOT NULL,
          size INTEGER NOT NULL,
          bytes BLOB NOT NULL,
          fetched_at INTEGER NOT NULL,
          PRIMARY KEY (provider_id, path, size)
        );
      ''');
      v3Raw.execute(
        "INSERT INTO gallery_items (origin, provider_id, path, seq, captured_at) "
        "VALUES ('cloud', 'space-a', '/Photos/a.jpg', 5, 1000);",
      );
      v3Raw.execute(
        "INSERT INTO sync_cursors (source, since) VALUES ('server', 5);",
      );
      v3Raw.execute('PRAGMA user_version = 3;');
      v3Raw.close();

      final db = GalleryMirrorDatabase(NativeDatabase(file));
      addTearDown(db.close);

      // The pre-existing row and its sync cursor survived - neither a new
      // index nor a new table may ever cost a user a full gallery re-fetch.
      final items = await db.select(db.galleryItems).get();
      expect(items, hasLength(1));
      expect(items.single.path, '/Photos/a.jpg');
      final cursor = await (db.select(db.syncCursors)
            ..where((t) => t.source.equals('server')))
          .getSingle();
      expect(cursor.since, 5);

      // All three indexes now exist, queryable straight from SQLite's
      // own schema table rather than assumed from the migration not
      // throwing.
      final indexNames = (await db
              .customSelect(
                  "SELECT name FROM sqlite_master WHERE type = 'index' "
                  "AND tbl_name = 'gallery_items'")
              .get())
          .map((row) => row.data['name'] as String)
          .toSet();
      expect(
        indexNames,
        containsAll(<String>[
          'idx_gallery_items_local_identity',
          'idx_gallery_items_origin_size_captured_at',
          'idx_gallery_items_captured_at_id',
        ]),
      );

      // The new table exists and is usable - empty, meaning "no explicit
      // choice yet" for every folder (GalleryMirror's DCIM default fills the
      // gap; see its class doc).
      final selections = await db.select(db.localFolderSelections).get();
      expect(selections, isEmpty);
      await db.into(db.localFolderSelections).insertOnConflictUpdate(
            LocalFolderSelectionsCompanion.insert(
              folderPath: 'DCIM/Camera/',
              selected: false,
            ),
          );
      final written = await db.select(db.localFolderSelections).get();
      expect(written, hasLength(1));
      expect(written.single.selected, isFalse);
    });

    test(
        'an app upgrade from v5 creates the ticket-18 Sync Pairs table '
        'without losing existing rows, the sync cursor, or the Local Folder '
        'selection table', () async {
      final file = File(p.join(tempDir.path, 'mirror.sqlite'));

      // A v5 database - everything through ticket 29's Local Folder
      // selection table exists, but ticket 18's Sync Pairs table does not.
      final v5Raw = sqlite3.sqlite3.open(file.path);
      v5Raw.execute('''
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
          orientation INTEGER NOT NULL DEFAULT 0,
          size INTEGER NOT NULL DEFAULT 0,
          mime TEXT NOT NULL DEFAULT '',
          unsupported TEXT NOT NULL DEFAULT '',
          metadata_pending INTEGER NOT NULL DEFAULT 0,
          UNIQUE(provider_id, path)
        );
      ''');
      v5Raw.execute('''
        CREATE TABLE sync_cursors (
          source TEXT NOT NULL PRIMARY KEY,
          since INTEGER NOT NULL DEFAULT 0,
          pending_cursor TEXT NULL
        );
      ''');
      v5Raw.execute('''
        CREATE TABLE cached_thumbnails (
          provider_id TEXT NOT NULL,
          path TEXT NOT NULL,
          size INTEGER NOT NULL,
          bytes BLOB NOT NULL,
          fetched_at INTEGER NOT NULL,
          PRIMARY KEY (provider_id, path, size)
        );
      ''');
      v5Raw.execute('''
        CREATE TABLE local_folder_selections (
          folder_path TEXT NOT NULL PRIMARY KEY,
          selected INTEGER NOT NULL
        );
      ''');
      v5Raw.execute(
        "INSERT INTO gallery_items (origin, provider_id, path, seq, captured_at) "
        "VALUES ('cloud', 'space-a', '/Photos/a.jpg', 5, 1000);",
      );
      v5Raw.execute(
        "INSERT INTO sync_cursors (source, since) VALUES ('server', 5);",
      );
      v5Raw.execute(
        "INSERT INTO local_folder_selections (folder_path, selected) "
        "VALUES ('DCIM/Camera/', 1);",
      );
      v5Raw.execute('PRAGMA user_version = 5;');
      v5Raw.close();

      final db = GalleryMirrorDatabase(NativeDatabase(file));
      addTearDown(db.close);

      // Everything that existed before the upgrade survived.
      final items = await db.select(db.galleryItems).get();
      expect(items, hasLength(1));
      expect(items.single.path, '/Photos/a.jpg');
      final cursor = await (db.select(db.syncCursors)
            ..where((t) => t.source.equals('server')))
          .getSingle();
      expect(cursor.since, 5);
      final selections = await db.select(db.localFolderSelections).get();
      expect(selections, hasLength(1));
      expect(selections.single.selected, isTrue);

      // The new Sync Pairs table exists and is usable.
      final pairs = await db.select(db.syncPairs).get();
      expect(pairs, isEmpty);
      await db.into(db.syncPairs).insert(
            SyncPairsCompanion.insert(
              localFolderPath: 'DCIM/Camera/',
              spaceProviderId: 'space-a',
              path: '/Photos/Phone',
            ),
          );
      final written = await db.select(db.syncPairs).get();
      expect(written, hasLength(1));
      expect(written.single.localFolderPath, 'DCIM/Camera/');
      expect(written.single.path, '/Photos/Phone');
    });

    test(
        'an app upgrade from v6 adds the ticket-20 verification columns and '
        'index without losing existing rows, the sync cursor, or the Sync '
        'Pairs table', () async {
      final file = File(p.join(tempDir.path, 'mirror.sqlite'));

      // A v6 database - everything through ticket 18's Sync Pairs table
      // exists, but ticket 20's upload_state/upload_target_* columns do not.
      final v6Raw = sqlite3.sqlite3.open(file.path);
      v6Raw.execute('''
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
          orientation INTEGER NOT NULL DEFAULT 0,
          size INTEGER NOT NULL DEFAULT 0,
          mime TEXT NOT NULL DEFAULT '',
          unsupported TEXT NOT NULL DEFAULT '',
          metadata_pending INTEGER NOT NULL DEFAULT 0,
          UNIQUE(provider_id, path)
        );
      ''');
      v6Raw.execute('''
        CREATE TABLE sync_cursors (
          source TEXT NOT NULL PRIMARY KEY,
          since INTEGER NOT NULL DEFAULT 0,
          pending_cursor TEXT NULL
        );
      ''');
      v6Raw.execute('''
        CREATE TABLE cached_thumbnails (
          provider_id TEXT NOT NULL,
          path TEXT NOT NULL,
          size INTEGER NOT NULL,
          bytes BLOB NOT NULL,
          fetched_at INTEGER NOT NULL,
          PRIMARY KEY (provider_id, path, size)
        );
      ''');
      v6Raw.execute('''
        CREATE TABLE local_folder_selections (
          folder_path TEXT NOT NULL PRIMARY KEY,
          selected INTEGER NOT NULL
        );
      ''');
      v6Raw.execute('''
        CREATE TABLE sync_pairs (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          local_folder_path TEXT NOT NULL,
          space_provider_id TEXT NOT NULL,
          path TEXT NOT NULL,
          created_at INTEGER NOT NULL DEFAULT 0,
          UNIQUE(local_folder_path)
        );
      ''');
      v6Raw.execute(
        "INSERT INTO gallery_items (origin, provider_id, path, seq, captured_at) "
        "VALUES ('cloud', 'space-a', '/Photos/a.jpg', 5, 1000);",
      );
      v6Raw.execute(
        "INSERT INTO sync_cursors (source, since) VALUES ('server', 5);",
      );
      v6Raw.execute(
        "INSERT INTO sync_pairs (local_folder_path, space_provider_id, path) "
        "VALUES ('DCIM/Camera/', 'space-a', '/Photos/Phone');",
      );
      v6Raw.execute('PRAGMA user_version = 6;');
      v6Raw.close();

      final db = GalleryMirrorDatabase(NativeDatabase(file));
      addTearDown(db.close);

      // Everything that existed before the upgrade survived.
      final items = await db.select(db.galleryItems).get();
      expect(items, hasLength(1));
      expect(items.single.path, '/Photos/a.jpg');
      // ...and the new columns are there, defaulting to null - "no upload
      // pending verification" for every pre-existing row.
      expect(items.single.uploadState, null);
      expect(items.single.uploadTargetProviderId, null);
      expect(items.single.uploadTargetPath, null);

      final cursor = await (db.select(db.syncCursors)
            ..where((t) => t.source.equals('server')))
          .getSingle();
      expect(cursor.since, 5);
      final pairs = await db.select(db.syncPairs).get();
      expect(pairs, hasLength(1));
      expect(pairs.single.localFolderPath, 'DCIM/Camera/');

      // The new index exists.
      final indexNames = (await db
              .customSelect(
                  "SELECT name FROM sqlite_master WHERE type = 'index' "
                  "AND tbl_name = 'gallery_items'")
              .get())
          .map((row) => row.data['name'] as String)
          .toSet();
      expect(indexNames, contains('idx_gallery_items_upload_target'));

      // The upgraded schema accepts writes to the new columns.
      await (db.update(db.galleryItems)
            ..where((t) => t.path.equals('/Photos/a.jpg')))
          .write(const GalleryItemsCompanion(
        uploadState: Value('uploaded'),
        uploadTargetProviderId: Value('space-b'),
        uploadTargetPath: Value('/Photos/b.jpg'),
      ));
      final updated = await (db.select(db.galleryItems)
            ..where((t) => t.path.equals('/Photos/a.jpg')))
          .getSingle();
      expect(updated.uploadState, 'uploaded');
      expect(updated.uploadTargetPath, '/Photos/b.jpg');
    });

    test(
        'an app upgrade from v7 adds the ticket-21 removedAt column and '
        'drops the old UNIQUE(local_folder_path) constraint, without losing '
        'the existing Sync Pair', () async {
      final file = File(p.join(tempDir.path, 'mirror.sqlite'));

      // A v7 database - everything through ticket 20's verification
      // columns exists, but sync_pairs still has ticket 18's original
      // UNIQUE(local_folder_path) constraint and no removed_at column.
      final v7Raw = sqlite3.sqlite3.open(file.path);
      v7Raw.execute('''
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
          orientation INTEGER NOT NULL DEFAULT 0,
          size INTEGER NOT NULL DEFAULT 0,
          mime TEXT NOT NULL DEFAULT '',
          unsupported TEXT NOT NULL DEFAULT '',
          metadata_pending INTEGER NOT NULL DEFAULT 0,
          upload_state TEXT NULL,
          upload_target_provider_id TEXT NULL,
          upload_target_path TEXT NULL,
          UNIQUE(provider_id, path)
        );
      ''');
      v7Raw.execute('''
        CREATE TABLE sync_cursors (
          source TEXT NOT NULL PRIMARY KEY,
          since INTEGER NOT NULL DEFAULT 0,
          pending_cursor TEXT NULL
        );
      ''');
      v7Raw.execute('''
        CREATE TABLE cached_thumbnails (
          provider_id TEXT NOT NULL,
          path TEXT NOT NULL,
          size INTEGER NOT NULL,
          bytes BLOB NOT NULL,
          fetched_at INTEGER NOT NULL,
          PRIMARY KEY (provider_id, path, size)
        );
      ''');
      v7Raw.execute('''
        CREATE TABLE local_folder_selections (
          folder_path TEXT NOT NULL PRIMARY KEY,
          selected INTEGER NOT NULL
        );
      ''');
      v7Raw.execute('''
        CREATE TABLE sync_pairs (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          local_folder_path TEXT NOT NULL,
          space_provider_id TEXT NOT NULL,
          path TEXT NOT NULL,
          created_at INTEGER NOT NULL DEFAULT 0,
          UNIQUE(local_folder_path)
        );
      ''');
      v7Raw.execute('''
        CREATE INDEX idx_gallery_items_upload_target
          ON gallery_items (upload_target_provider_id, upload_target_path);
      ''');
      v7Raw.execute(
        "INSERT INTO gallery_items (origin, provider_id, path, seq, captured_at) "
        "VALUES ('cloud', 'space-a', '/Photos/a.jpg', 5, 1000);",
      );
      v7Raw.execute(
        "INSERT INTO sync_cursors (source, since) VALUES ('server', 5);",
      );
      v7Raw.execute(
        "INSERT INTO sync_pairs (local_folder_path, space_provider_id, path) "
        "VALUES ('DCIM/Camera/', 'space-a', '/Photos/Phone');",
      );
      v7Raw.execute('PRAGMA user_version = 7;');
      v7Raw.close();

      final db = GalleryMirrorDatabase(NativeDatabase(file));
      addTearDown(db.close);

      // Everything that existed before the upgrade survived, and the
      // pre-existing pair defaults to active (removedAt null).
      final pairs = await db.select(db.syncPairs).get();
      expect(pairs, hasLength(1));
      expect(pairs.single.localFolderPath, 'DCIM/Camera/');
      expect(pairs.single.path, '/Photos/Phone');
      expect(pairs.single.removedAt, null);

      final items = await db.select(db.galleryItems).get();
      expect(items, hasLength(1));
      expect(items.single.path, '/Photos/a.jpg');

      final cursor = await (db.select(db.syncCursors)
            ..where((t) => t.source.equals('server')))
          .getSingle();
      expect(cursor.since, 5);

      // The old UNIQUE(local_folder_path) constraint is gone: a second row
      // for the SAME local folder - what a retarget produces, an old
      // removed pair plus a newly created active one - is now accepted
      // rather than rejected.
      await (db.update(db.syncPairs)
            ..where((t) => t.localFolderPath.equals('DCIM/Camera/')))
          .write(SyncPairsCompanion(removedAt: Value(DateTime.now()
              .millisecondsSinceEpoch)));
      await db.into(db.syncPairs).insert(
            SyncPairsCompanion.insert(
              localFolderPath: 'DCIM/Camera/',
              spaceProviderId: 'space-b',
              path: '/Photos/PhoneNew',
              createdAt: Value(DateTime.now().millisecondsSinceEpoch),
            ),
          );
      final afterRetarget = await (db.select(db.syncPairs)
            ..orderBy([(t) => OrderingTerm(expression: t.id)]))
          .get();
      expect(afterRetarget, hasLength(2));
      expect(afterRetarget.every((p) => p.localFolderPath == 'DCIM/Camera/'),
          isTrue);
      expect(afterRetarget[0].removedAt != null, isTrue);
      expect(afterRetarget[1].removedAt, null);
      expect(afterRetarget[1].path, '/Photos/PhoneNew');
    });

    test(
        'an app upgrade from v8 adds the ticket-22 sync_run_state table '
        'without losing existing rows, and GalleryMirror.syncRunState reads '
        'an idle default from the new, empty table', () async {
      final file = File(p.join(tempDir.path, 'mirror.sqlite'));

      // A v8 database - everything through ticket 21's Sync Pair lifecycle
      // exists (removed_at and no more UNIQUE(local_folder_path)), but there
      // is no sync_run_state table yet.
      final v8Raw = sqlite3.sqlite3.open(file.path);
      v8Raw.execute('''
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
          orientation INTEGER NOT NULL DEFAULT 0,
          size INTEGER NOT NULL DEFAULT 0,
          mime TEXT NOT NULL DEFAULT '',
          unsupported TEXT NOT NULL DEFAULT '',
          metadata_pending INTEGER NOT NULL DEFAULT 0,
          upload_state TEXT NULL,
          upload_target_provider_id TEXT NULL,
          upload_target_path TEXT NULL,
          UNIQUE(provider_id, path)
        );
      ''');
      v8Raw.execute('''
        CREATE TABLE sync_cursors (
          source TEXT NOT NULL PRIMARY KEY,
          since INTEGER NOT NULL DEFAULT 0,
          pending_cursor TEXT NULL
        );
      ''');
      v8Raw.execute('''
        CREATE TABLE cached_thumbnails (
          provider_id TEXT NOT NULL,
          path TEXT NOT NULL,
          size INTEGER NOT NULL,
          bytes BLOB NOT NULL,
          fetched_at INTEGER NOT NULL,
          PRIMARY KEY (provider_id, path, size)
        );
      ''');
      v8Raw.execute('''
        CREATE TABLE local_folder_selections (
          folder_path TEXT NOT NULL PRIMARY KEY,
          selected INTEGER NOT NULL
        );
      ''');
      v8Raw.execute('''
        CREATE TABLE sync_pairs (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          local_folder_path TEXT NOT NULL,
          space_provider_id TEXT NOT NULL,
          path TEXT NOT NULL,
          created_at INTEGER NOT NULL DEFAULT 0,
          removed_at INTEGER NULL
        );
      ''');
      v8Raw.execute('''
        CREATE INDEX idx_gallery_items_upload_target
          ON gallery_items (upload_target_provider_id, upload_target_path);
      ''');
      v8Raw.execute(
        "INSERT INTO gallery_items (origin, provider_id, path, seq, captured_at) "
        "VALUES ('cloud', 'space-a', '/Photos/a.jpg', 5, 1000);",
      );
      v8Raw.execute(
        "INSERT INTO sync_pairs (local_folder_path, space_provider_id, path) "
        "VALUES ('DCIM/Camera/', 'space-a', '/Photos/Phone');",
      );
      v8Raw.execute('PRAGMA user_version = 8;');
      v8Raw.close();

      final db = GalleryMirrorDatabase(NativeDatabase(file));
      addTearDown(db.close);

      // Everything that existed before the upgrade survived.
      final items = await db.select(db.galleryItems).get();
      expect(items, hasLength(1));
      expect(items.single.path, '/Photos/a.jpg');
      final pairs = await db.select(db.syncPairs).get();
      expect(pairs, hasLength(1));
      expect(pairs.single.localFolderPath, 'DCIM/Camera/');

      // The new table exists and is empty - GalleryMirror.syncRunState
      // reads an idle, all-zero default from it rather than erroring, so an
      // upgraded device with no run in progress reads exactly as a fresh
      // install would.
      final rows = await db.select(db.syncRunState).get();
      expect(rows, isEmpty);
      final state = await GalleryMirror(db).syncRunState();
      expect(state.status, syncStatusIdle);
      expect(state.totalItems, 0);
    });

    test(
        'an app upgrade from v9 creates the ticket-23 token_refresh_lock '
        'table without losing existing rows or the sync_run_state row',
        () async {
      final file = File(p.join(tempDir.path, 'mirror.sqlite'));

      // A v9 database - everything through ticket 22's SyncRunState exists,
      // but there is no token_refresh_lock table yet.
      final v9Raw = sqlite3.sqlite3.open(file.path);
      v9Raw.execute('''
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
          orientation INTEGER NOT NULL DEFAULT 0,
          size INTEGER NOT NULL DEFAULT 0,
          mime TEXT NOT NULL DEFAULT '',
          unsupported TEXT NOT NULL DEFAULT '',
          metadata_pending INTEGER NOT NULL DEFAULT 0,
          upload_state TEXT NULL,
          upload_target_provider_id TEXT NULL,
          upload_target_path TEXT NULL,
          UNIQUE(provider_id, path)
        );
      ''');
      v9Raw.execute('''
        CREATE TABLE sync_cursors (
          source TEXT NOT NULL PRIMARY KEY,
          since INTEGER NOT NULL DEFAULT 0,
          pending_cursor TEXT NULL
        );
      ''');
      v9Raw.execute('''
        CREATE TABLE cached_thumbnails (
          provider_id TEXT NOT NULL,
          path TEXT NOT NULL,
          size INTEGER NOT NULL,
          bytes BLOB NOT NULL,
          fetched_at INTEGER NOT NULL,
          PRIMARY KEY (provider_id, path, size)
        );
      ''');
      v9Raw.execute('''
        CREATE TABLE local_folder_selections (
          folder_path TEXT NOT NULL PRIMARY KEY,
          selected INTEGER NOT NULL
        );
      ''');
      v9Raw.execute('''
        CREATE TABLE sync_pairs (
          id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
          local_folder_path TEXT NOT NULL,
          space_provider_id TEXT NOT NULL,
          path TEXT NOT NULL,
          created_at INTEGER NOT NULL DEFAULT 0,
          removed_at INTEGER NULL
        );
      ''');
      v9Raw.execute('''
        CREATE INDEX idx_gallery_items_upload_target
          ON gallery_items (upload_target_provider_id, upload_target_path);
      ''');
      v9Raw.execute('''
        CREATE TABLE sync_run_state (
          id TEXT NOT NULL PRIMARY KEY,
          status TEXT NOT NULL,
          total_items INTEGER NOT NULL DEFAULT 0,
          completed_items INTEGER NOT NULL DEFAULT 0,
          failed_items INTEGER NOT NULL DEFAULT 0,
          total_bytes INTEGER NOT NULL DEFAULT 0,
          completed_bytes INTEGER NOT NULL DEFAULT 0,
          last_error TEXT NULL,
          updated_at INTEGER NOT NULL DEFAULT 0
        );
      ''');
      v9Raw.execute(
        "INSERT INTO gallery_items (origin, provider_id, path, seq, captured_at) "
        "VALUES ('cloud', 'space-a', '/Photos/a.jpg', 5, 1000);",
      );
      v9Raw.execute(
        "INSERT INTO sync_run_state (id, status, total_items) "
        "VALUES ('default', 'paused', 7);",
      );
      v9Raw.execute('PRAGMA user_version = 9;');
      v9Raw.close();

      final db = GalleryMirrorDatabase(NativeDatabase(file));
      addTearDown(db.close);

      // Everything that existed before the upgrade survived.
      final items = await db.select(db.galleryItems).get();
      expect(items, hasLength(1));
      expect(items.single.path, '/Photos/a.jpg');
      final runState = await GalleryMirror(db).syncRunState();
      expect(runState.status, 'paused');
      expect(runState.totalItems, 7);

      // The new table exists, starts empty (the lock reads as free), and
      // accepts the atomic acquire GalleryMirror.tryAcquireTokenRefreshLock
      // relies on.
      final rows = await db.select(db.tokenRefreshLock).get();
      expect(rows, isEmpty);
      final mirror = GalleryMirror(db);
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(
        await mirror.tryAcquireTokenRefreshLock(
          holder: 'ui',
          nowMillis: now,
          leaseMillis: 30000,
        ),
        isTrue,
      );
    });

    test('a fresh install creates the current schema directly via onCreate',
        () async {
      final db = GalleryMirrorDatabase(NativeDatabase.memory());
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
