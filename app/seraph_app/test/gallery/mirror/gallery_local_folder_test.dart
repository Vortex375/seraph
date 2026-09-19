import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_delta_models.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';

import '../gallery_test_support.dart';

GalleryDeltaItem _cloudItem({
  String providerId = 'space-a',
  required String path,
  required int seq,
  required int capturedAt,
  int size = 2048,
}) {
  return GalleryDeltaItem(
    providerId: providerId,
    path: path,
    seq: seq,
    tombstone: false,
    capturedAt: capturedAt,
    size: size,
  );
}

/// Ticket 29's mirror-seam coverage: everything the ticket asks about Local
/// Folder selection - enumeration from rows already in the mirror, the DCIM
/// first-run default, the deselect/reselect round trip, and "an unselected
/// folder's device copy is invisible everywhere at once" - driven directly
/// against [GalleryMirror], exactly the seam ticket 13 established.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GalleryMirror Local Folder selection', () {
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;

    setUp(() {
      db = GalleryMirrorDatabase(NativeDatabase.memory());
      mirror = GalleryMirror(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('listLocalFolders enumerates folders from mirror rows, with counts',
        () async {
      await mirror.applyLocalScan([
        localMediaItem(
            relativePath: 'DCIM/Camera/', displayName: 'a.jpg', size: 1),
        localMediaItem(
            relativePath: 'DCIM/Camera/', displayName: 'b.jpg', size: 2),
        localMediaItem(
            relativePath: 'Pictures/Screenshots/',
            displayName: 'c.jpg',
            size: 3),
      ]);

      final folders = await mirror.listLocalFolders();
      final byPath = {for (final f in folders) f.path: f};

      expect(byPath['DCIM/Camera/']!.photoCount, 2);
      expect(byPath['Pictures/Screenshots/']!.photoCount, 1);
    });

    test('the default is the camera folders: DCIM selected, everything else '
        'not - before any explicit choice is ever made', () async {
      await mirror.applyLocalScan([
        localMediaItem(relativePath: 'DCIM/Camera/', displayName: 'a.jpg'),
        localMediaItem(
            relativePath: 'DCIM/Camera/Edited/', displayName: 'b.jpg'),
        localMediaItem(
            relativePath: 'Pictures/Screenshots/', displayName: 'c.jpg'),
        localMediaItem(
            relativePath: 'WhatsApp/Media/WhatsApp Images/',
            displayName: 'd.jpg'),
      ]);

      final byPath = {
        for (final f in await mirror.listLocalFolders()) f.path: f.selected,
      };
      expect(byPath['DCIM/Camera/'], isTrue);
      expect(byPath['DCIM/Camera/Edited/'], isTrue,
          reason: 'DCIM and everything beneath it');
      expect(byPath['Pictures/Screenshots/'], isFalse);
      expect(byPath['WhatsApp/Media/WhatsApp Images/'], isFalse);
    });

    test(
        'a folder that appears later is off unless it is under DCIM - no '
        'second scan or platform call needed to know this', () async {
      await mirror.applyLocalScan([
        localMediaItem(relativePath: 'DCIM/Camera/', displayName: 'a.jpg'),
      ]);
      // Nothing has ever been toggled yet, so this later scan is exactly
      // "a folder appearing later", not a first run.
      await mirror.applyLocalScan([
        localMediaItem(relativePath: 'DCIM/Camera/', displayName: 'a.jpg'),
        localMediaItem(relativePath: 'DCIM/Screenshots/', displayName: 'e.jpg'),
        localMediaItem(relativePath: 'Download/', displayName: 'f.jpg'),
      ]);

      final byPath = {
        for (final f in await mirror.listLocalFolders()) f.path: f.selected,
      };
      expect(byPath['DCIM/Screenshots/'], isTrue);
      expect(byPath['Download/'], isFalse);
    });

    test('a folder can be deselected and reselected, and stays listed either '
        'way', () async {
      await mirror.applyLocalScan([
        localMediaItem(relativePath: 'DCIM/Camera/', displayName: 'a.jpg'),
      ]);

      await mirror.setLocalFolderSelected('DCIM/Camera/', false);
      var folders = await mirror.listLocalFolders();
      expect(folders, hasLength(1));
      expect(folders.single.selected, isFalse);

      await mirror.setLocalFolderSelected('DCIM/Camera/', true);
      folders = await mirror.listLocalFolders();
      expect(folders, hasLength(1));
      expect(folders.single.selected, isTrue);
    });

    test(
        'the first-run seed happens exactly once: deselecting a camera '
        'folder survives a restart rather than being re-derived', () async {
      await mirror.applyLocalScan([
        localMediaItem(relativePath: 'DCIM/Camera/', displayName: 'a.jpg'),
      ]);
      expect((await mirror.listLocalFolders()).single.selected, isTrue,
          reason: 'the DCIM default, before any explicit choice');

      await mirror.setLocalFolderSelected('DCIM/Camera/', false);

      // Simulate an app restart: a fresh GalleryMirror over the SAME
      // database - the mirror itself holds no in-memory state, so this is
      // exactly what re-opening the app does.
      final restarted = GalleryMirror(db);
      expect((await restarted.listLocalFolders()).single.selected, isFalse,
          reason: 'the user\'s choice must never be re-derived from the '
              'DCIM default afterwards');
    });

    test(
        'a Device only photo in an unselected folder does not appear in the '
        'gallery and is not counted as not-backed-up', () async {
      await mirror.applyLocalScan([
        localMediaItem(
            relativePath: 'Pictures/Screenshots/',
            displayName: 'shot.jpg',
            size: 111,
            dateTakenMillis: 50000),
      ]);
      // Unselected by the DCIM default already, but toggle explicitly too so
      // the test also covers the override path.
      await mirror.setLocalFolderSelected('Pictures/Screenshots/', false);

      expect(await mirror.queryItems(), isEmpty);
      expect(await mirror.totalCount(), 0);
      expect(
          await mirror.totalCount(filter: GalleryAvailabilityFilter.notBackedUp),
          0);

      final summary = await mirror.availabilitySummary();
      expect(summary.deviceOnly, 0);
      expect(summary.notBackedUp, 0);
      expect(summary.total, 0);
    });

    test(
        'reselecting the folder brings the SAME row back rather than a new '
        'one - the scan never stopped seeing it', () async {
      final item = localMediaItem(
        relativePath: 'Pictures/Screenshots/',
        displayName: 'shot.jpg',
        size: 111,
        dateTakenMillis: 50000,
      );
      await mirror.applyLocalScan([item]);
      await mirror.setLocalFolderSelected('Pictures/Screenshots/', false);
      expect(await mirror.totalCount(), 0);

      // Full scan continues to run regardless of the selection (design
      // record D21 / ticket 29's core rule) - re-applying the very same scan
      // while the folder is hidden must not create a second row.
      await mirror.applyLocalScan([item]);

      await mirror.setLocalFolderSelected('Pictures/Screenshots/', true);
      final items = await mirror.queryItems();
      expect(items, hasLength(1),
          reason: 'deselecting and reselecting must produce no duplicate row');
      expect(items.single.localDisplayName, 'shot.jpg');
    });

    test(
        'a Synced photo whose device copy is in an unselected folder appears '
        'as Cloud only - in the grid, its badge, the Cloud only filter and '
        'the counts, all at once', () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [_cloudItem(path: '/Photos/a.jpg', seq: 1, capturedAt: 500000)],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'Pictures/Screenshots/',
          displayName: 'a-device.jpg',
          size: 2048, // matches the cloud item, so this dedups onto one row
          dateTakenMillis: 500000 * 1000,
        ),
      ]);
      // 'Pictures/Screenshots/' is not under DCIM, so it defaults to
      // unselected - select it explicitly first so "before hiding it, this
      // really is one Synced row" is a meaningful check, not the default
      // already doing this test's job for it.
      await mirror.setLocalFolderSelected('Pictures/Screenshots/', true);
      final beforeHide = await mirror.queryItems();
      expect(beforeHide, hasLength(1));
      expect(beforeHide.single.availability, GalleryAvailability.synced);

      await mirror.setLocalFolderSelected('Pictures/Screenshots/', false);

      // In the grid: exactly one row, at the same Capture Date.
      final items = await mirror.queryItems();
      expect(items, hasLength(1));
      final item = items.single;

      // Its badge:
      expect(item.availability, GalleryAvailability.cloudOnly);
      // Never asks the Local Source for pixels that are supposed to be
      // invisible.
      expect(item.hasLocalCopy, isFalse);
      // The cloud identity is still there - the row is still usable as a
      // Cloud-only item, not a broken one.
      expect(item.path, '/Photos/a.jpg');

      // Under the Cloud only filter:
      final cloudOnly =
          await mirror.queryItems(filter: GalleryAvailabilityFilter.cloudOnly);
      expect(cloudOnly, hasLength(1));
      expect(cloudOnly.single.path, '/Photos/a.jpg');

      // Never under "not backed up" - the device copy being hidden must not
      // make an otherwise-synced photo look un-backed-up.
      final notBackedUp = await mirror.queryItems(
          filter: GalleryAvailabilityFilter.notBackedUp);
      expect(notBackedUp, isEmpty);

      // And the counts:
      final summary = await mirror.availabilitySummary();
      expect(summary.deviceOnly, 0);
      expect(summary.synced, 0);
      expect(summary.cloudOnly, 1);
      expect(summary.total, 1);
    });

    test(
        'the summary and the Availability filter agree with the grid under a '
        'mixed selection', () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(path: '/Photos/cloud-only.jpg', seq: 1, capturedAt: 100),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));
      await mirror.applyLocalScan([
        // Selected folder (default DCIM): stays Device only.
        localMediaItem(
            relativePath: 'DCIM/Camera/',
            displayName: 'kept-device.jpg',
            size: 10,
            dateTakenMillis: 200000),
        // Unselected folder: fully hidden.
        localMediaItem(
            relativePath: 'Pictures/Screenshots/',
            displayName: 'hidden-device.jpg',
            size: 20,
            dateTakenMillis: 300000),
      ]);

      final all = await mirror.queryItems();
      final notBackedUp =
          await mirror.queryItems(filter: GalleryAvailabilityFilter.notBackedUp);
      final cloudOnly =
          await mirror.queryItems(filter: GalleryAvailabilityFilter.cloudOnly);
      final summary = await mirror.availabilitySummary();

      expect(all, hasLength(2),
          reason: 'cloud-only.jpg and kept-device.jpg; the hidden one is gone');
      expect(await mirror.totalCount(), summary.total);
      expect(notBackedUp, hasLength(summary.notBackedUp));
      expect(cloudOnly, hasLength(summary.cloudOnly));
      expect(
          await mirror.totalCount(filter: GalleryAvailabilityFilter.notBackedUp),
          summary.notBackedUp);
      expect(
          await mirror.totalCount(filter: GalleryAvailabilityFilter.cloudOnly),
          summary.cloudOnly);
    });

    test('the full media-store scan keeps seeing an unselected folder - '
        'applyLocalScan removes a row only when the FILE is gone, never '
        'because its folder is unselected', () async {
      final item = localMediaItem(
        relativePath: 'Pictures/Screenshots/',
        displayName: 'shot.jpg',
        size: 111,
        dateTakenMillis: 50000,
      );
      await mirror.applyLocalScan([item]);
      await mirror.setLocalFolderSelected('Pictures/Screenshots/', false);

      // The row is invisible to every read-path query...
      expect(await mirror.totalCount(), 0);

      // ...but a raw read of the underlying table shows it is still there,
      // exactly as the full scan left it - the scan never filtered anything.
      final raw = await db.select(db.galleryItems).get();
      expect(raw, hasLength(1));
      expect(raw.single.localDisplayName, 'shot.jpg');

      // And a folder disappearing from a later scan is still what removes
      // it - not the selection.
      await mirror.applyLocalScan([]);
      final rawAfter = await db.select(db.galleryItems).get();
      expect(rawAfter, isEmpty);
    });

    test('setLocalFolderSelected never touches GalleryItems, only the '
        'selection table', () async {
      await mirror.applyLocalScan([
        localMediaItem(relativePath: 'DCIM/Camera/', displayName: 'a.jpg'),
      ]);
      final before = await db.select(db.galleryItems).get();

      await mirror.setLocalFolderSelected('DCIM/Camera/', false);
      await mirror.setLocalFolderSelected('DCIM/Camera/', true);

      final after = await db.select(db.galleryItems).get();
      expect(after, equals(before));
    });
  });
}
