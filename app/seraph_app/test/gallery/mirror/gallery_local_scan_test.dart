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
  bool tombstone = false,
}) {
  return GalleryDeltaItem(
    providerId: providerId,
    path: path,
    seq: seq,
    tombstone: tombstone,
    capturedAt: capturedAt,
    size: size,
  );
}

/// Ticket 15's mirror-seam coverage requirement: everything about scanning a
/// fake Local Source, merging it with cloud items, computing Availability,
/// filtering and summarising is driven directly against [GalleryMirror] -
/// exactly the seam ticket 13 established and the spec names as seam 7 ("the
/// app's local mirror - the primary device-side seam").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GalleryMirror.applyLocalScan', () {
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;

    setUp(() {
      db = GalleryMirrorDatabase(NativeDatabase.memory());
      mirror = GalleryMirror(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('a device photo with no cloud match becomes a Device only item',
        () async {
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'IMG_0001.jpg',
          size: 4096,
          dateTakenMillis: 1700000000000,
        ),
      ]);

      final items = await mirror.queryItems();
      expect(items, hasLength(1));
      expect(items.single.availability, GalleryAvailability.deviceOnly);
      expect(items.single.capturedAt, 1700000000);
      expect(items.single.providerId, isNull);
      expect(items.single.localDisplayName, 'IMG_0001.jpg');
    });

    test(
        'a device photo matching an existing cloud item by size and capture '
        'date dedups onto the SAME row - Synced, not two items', () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [_cloudItem(path: '/Photos/a.jpg', seq: 1, capturedAt: 500000)],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));
      final beforeId = (await mirror.queryItems()).single.id;

      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'IMG_0002.jpg',
          size: 2048, // matches the cloud item's size
          dateTakenMillis: 500000 * 1000, // matches its capturedAt (seconds)
        ),
      ]);

      final items = await mirror.queryItems();
      expect(items, hasLength(1),
          reason: 'the photo must appear exactly once');
      expect(items.single.id, beforeId,
          reason: 'merging must not change the row - same timeline position');
      expect(items.single.availability, GalleryAvailability.synced);
      expect(items.single.providerId, 'space-a');
      expect(items.single.path, '/Photos/a.jpg');
      expect(items.single.localDisplayName, 'IMG_0002.jpg');
      expect(items.single.capturedAt, 500000,
          reason: 'merging must not move the row - same Capture Date');
    });

    test(
        'a cloud item arriving AFTER a device item merges onto the SAME row '
        'too - order of arrival must not decide one row vs two', () async {
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'IMG_0003.jpg',
          size: 3000,
          dateTakenMillis: 600000 * 1000,
        ),
      ]);
      final beforeId = (await mirror.queryItems()).single.id;
      expect((await mirror.queryItems()).single.availability,
          GalleryAvailability.deviceOnly);

      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(
              path: '/Photos/b.jpg', seq: 1, capturedAt: 600000, size: 3000)
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));

      final items = await mirror.queryItems();
      expect(items, hasLength(1));
      expect(items.single.id, beforeId);
      expect(items.single.availability, GalleryAvailability.synced);
      expect(items.single.path, '/Photos/b.jpg');
      expect(items.single.localDisplayName, 'IMG_0003.jpg');
    });

    test(
        'a photo whose media-store id changed between scans is not treated '
        'as a new photo', () async {
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'IMG_0004.jpg',
          size: 5000,
          dateTakenMillis: 700000000,
          mediaStoreId: 111,
        ),
      ]);
      expect(await mirror.totalCount(), 1);

      // Same local identity, but the platform assigned a new row id - a file
      // deleted and recreated, moved, or restored by another app.
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'IMG_0004.jpg',
          size: 5000,
          dateTakenMillis: 700000000,
          mediaStoreId: 999,
        ),
      ]);

      expect(await mirror.totalCount(), 1,
          reason: 'identity, not media-store id, decides whether this is a '
              'new photo');
    });

    test(
        'a Device only photo missing from a later scan is removed from the '
        'gallery', () async {
      final item = localMediaItem(
        relativePath: 'DCIM/Camera/',
        displayName: 'IMG_0005.jpg',
        size: 6000,
        dateTakenMillis: 800000000,
      );
      await mirror.applyLocalScan([item]);
      expect(await mirror.totalCount(), 1);

      await mirror.applyLocalScan([]); // the file is gone
      expect(await mirror.totalCount(), 0);
    });

    test(
        'a Synced photo missing from a later scan becomes Cloud only rather '
        'than disappearing', () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [_cloudItem(path: '/Photos/c.jpg', seq: 1, capturedAt: 900000)],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'IMG_0006.jpg',
          size: 2048,
          dateTakenMillis: 900000 * 1000,
        ),
      ]);
      final merged = (await mirror.queryItems()).single;
      expect(merged.availability, GalleryAvailability.synced);
      final id = merged.id;

      // The device deletes its copy; the next scan no longer sees it.
      await mirror.applyLocalScan([]);

      final items = await mirror.queryItems();
      expect(items, hasLength(1),
          reason: 'the cloud copy still exists - the item must not vanish');
      expect(items.single.id, id);
      expect(items.single.availability, GalleryAvailability.cloudOnly);
      expect(items.single.path, '/Photos/c.jpg');
      expect(items.single.localDisplayName, isNull);
    });

    test(
        'a cloud tombstone on a Synced item demotes it to Device only rather '
        'than deleting it', () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [_cloudItem(path: '/Photos/d.jpg', seq: 1, capturedAt: 111000)],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'IMG_0007.jpg',
          size: 2048,
          dateTakenMillis: 111000 * 1000,
        ),
      ]);
      expect((await mirror.queryItems()).single.availability,
          GalleryAvailability.synced);

      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(
              path: '/Photos/d.jpg', seq: 2, capturedAt: 111000, tombstone: true)
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));

      final items = await mirror.queryItems();
      expect(items, hasLength(1),
          reason: 'the device copy still exists - the item must not vanish');
      expect(items.single.availability, GalleryAvailability.deviceOnly);
      expect(items.single.providerId, isNull);
      expect(items.single.localDisplayName, 'IMG_0007.jpg');
    });

    test('device and cloud items interleave in one Capture-Date order',
        () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(path: '/Photos/newest.jpg', seq: 1, capturedAt: 300),
          _cloudItem(path: '/Photos/oldest.jpg', seq: 2, capturedAt: 100),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'middle.jpg',
          size: 999,
          dateTakenMillis: 200000,
        ),
      ]);

      final items = await mirror.queryItems();
      expect(items.map((i) => i.availability), [
        GalleryAvailability.cloudOnly,
        GalleryAvailability.deviceOnly,
        GalleryAvailability.cloudOnly,
      ]);
      expect(items[0].capturedAt, 300);
      expect(items[1].capturedAt, 200);
      expect(items[2].capturedAt, 100);
    });

    test('filtering to "not backed up" returns only Device only items',
        () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [_cloudItem(path: '/Photos/cloud.jpg', seq: 1, capturedAt: 100)],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'device.jpg',
          size: 111,
          dateTakenMillis: 50000,
        ),
      ]);

      final notBackedUp = await mirror.queryItems(
          filter: GalleryAvailabilityFilter.notBackedUp);
      expect(notBackedUp, hasLength(1));
      expect(notBackedUp.single.localDisplayName, 'device.jpg');
      expect(
          await mirror.totalCount(filter: GalleryAvailabilityFilter.notBackedUp),
          1);

      final cloudOnly =
          await mirror.queryItems(filter: GalleryAvailabilityFilter.cloudOnly);
      expect(cloudOnly, hasLength(1));
      expect(cloudOnly.single.path, '/Photos/cloud.jpg');

      expect(await mirror.totalCount(), 2,
          reason: 'the unfiltered count must still cover everything');
    });

    test('availabilitySummary counts every Availability, over the whole mirror',
        () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _cloudItem(path: '/Photos/cloud-1.jpg', seq: 1, capturedAt: 100),
          _cloudItem(path: '/Photos/cloud-2.jpg', seq: 2, capturedAt: 200),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'device-only.jpg',
          size: 111,
          dateTakenMillis: 50000,
        ),
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'synced.jpg',
          size: 2048,
          dateTakenMillis: 100 * 1000, // matches cloud-1.jpg
        ),
      ]);

      final summary = await mirror.availabilitySummary();
      expect(summary.deviceOnly, 1);
      expect(summary.synced, 1);
      expect(summary.cloudOnly, 1);
      expect(summary.backedUp, 2);
      expect(summary.notBackedUp, 1);
      expect(summary.total, 3);
    });
  });
}
