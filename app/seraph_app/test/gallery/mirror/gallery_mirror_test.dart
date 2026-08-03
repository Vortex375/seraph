import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_delta_models.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';

GalleryDeltaItem _item({
  String providerId = 'space-a',
  required String path,
  required int seq,
  int capturedAt = 1000,
  bool tombstone = false,
}) {
  return GalleryDeltaItem(
    providerId: providerId,
    path: path,
    seq: seq,
    tombstone: tombstone,
    capturedAt: capturedAt,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GalleryMirror', () {
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;

    setUp(() {
      db = GalleryMirrorDatabase(NativeDatabase.memory());
      mirror = GalleryMirror(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('cold start: since defaults to 0 and the mirror starts empty',
        () async {
      expect(await mirror.since(), 0);
      expect(await mirror.pendingCursor(), isNull);
      final page = await mirror.queryPage();
      expect(page.items, isEmpty);
      expect(page.totalCount, 0);
    });

    test(
        'a cold-start page (hasMore false) populates the mirror and stores since',
        () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _item(path: '/Photos/a.jpg', seq: 1, capturedAt: 100),
          _item(path: '/Photos/b.jpg', seq: 2, capturedAt: 200),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));

      expect(await mirror.since(), 2);
      expect(await mirror.pendingCursor(), isNull);

      final page = await mirror.queryPage();
      expect(page.totalCount, 2);
      expect(page.items.map((i) => i.path), ['/Photos/b.jpg', '/Photos/a.jpg']);
    });

    test('a subsequent sync applies only the new page and advances since',
        () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [_item(path: '/Photos/a.jpg', seq: 1, capturedAt: 100)],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));

      await mirror.applyPage(GalleryDeltaResponse(
        items: [_item(path: '/Photos/b.jpg', seq: 2, capturedAt: 200)],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));

      expect(await mirror.since(), 2);
      final page = await mirror.queryPage();
      expect(page.totalCount, 2);
      expect(page.items.map((i) => i.path), ['/Photos/b.jpg', '/Photos/a.jpg']);
    });

    test(
        're-applying an item at the same identity updates it in place (dedup at write time)',
        () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [_item(path: '/Photos/a.jpg', seq: 1, capturedAt: 100)],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));

      await mirror.applyPage(GalleryDeltaResponse(
        items: [_item(path: '/Photos/a.jpg', seq: 3, capturedAt: 999)],
        nextCursor: '',
        hasMore: false,
        nextSince: 3,
      ));

      final page = await mirror.queryPage();
      expect(page.totalCount, 1);
      expect(page.items.single.capturedAt, 999);
      expect(page.items.single.seq, 3);
    });

    test('a tombstone removes the item from the mirror', () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _item(path: '/Photos/a.jpg', seq: 1, capturedAt: 100),
          _item(path: '/Photos/b.jpg', seq: 2, capturedAt: 200),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));

      await mirror.applyPage(GalleryDeltaResponse(
        items: [_item(path: '/Photos/a.jpg', seq: 3, tombstone: true)],
        nextCursor: '',
        hasMore: false,
        nextSince: 3,
      ));

      final page = await mirror.queryPage();
      expect(page.totalCount, 1);
      expect(page.items.single.path, '/Photos/b.jpg');
      expect(await mirror.since(), 3);
    });

    test(
        'a poll interrupted mid-page persists a pending cursor without moving since',
        () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [_item(path: '/Photos/a.jpg', seq: 1, capturedAt: 100)],
        nextCursor: 'cursor-after-page-1',
        hasMore: true,
        nextSince: 0, // not meaningful while hasMore is true
      ));

      // since must NOT have moved yet - the poll (started at since=0) is not
      // finished, so a restart here must resume, not skip ahead.
      expect(await mirror.since(), 0);
      expect(await mirror.pendingCursor(), 'cursor-after-page-1');

      // Item from the first page is already visible - a crash now does not
      // lose it.
      final midPage = await mirror.queryPage();
      expect(midPage.totalCount, 1);

      // Resuming (as GallerySyncService would after a restart) with the
      // stored cursor applies the second page and finishes the poll.
      await mirror.applyPage(GalleryDeltaResponse(
        items: [_item(path: '/Photos/b.jpg', seq: 2, capturedAt: 200)],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));

      expect(await mirror.since(), 2);
      expect(await mirror.pendingCursor(), isNull);
      final finalPage = await mirror.queryPage();
      expect(finalPage.totalCount, 2);
    });

    test('resuming a mid-page sync does not duplicate items already applied',
        () async {
      // First page of a poll, interrupted.
      await mirror.applyPage(GalleryDeltaResponse(
        items: [_item(path: '/Photos/a.jpg', seq: 1, capturedAt: 100)],
        nextCursor: 'cursor-after-page-1',
        hasMore: true,
        nextSince: 0,
      ));

      // Simulate the client re-requesting from the persisted pendingCursor
      // and receiving the SAME first page again (e.g. the reply for the
      // resumed request raced with, or replaced, the one that was in
      // flight when the app died) plus a second page finishing the poll.
      await mirror.applyPage(GalleryDeltaResponse(
        items: [_item(path: '/Photos/a.jpg', seq: 1, capturedAt: 100)],
        nextCursor: 'cursor-after-page-1',
        hasMore: true,
        nextSince: 0,
      ));
      await mirror.applyPage(GalleryDeltaResponse(
        items: [_item(path: '/Photos/b.jpg', seq: 2, capturedAt: 200)],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));

      final page = await mirror.queryPage();
      expect(page.totalCount, 2,
          reason: 're-applying the same page must not duplicate rows');
    });

    test(
        'queryPage orders by Capture Date descending and pages with a total count',
        () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          _item(path: '/Photos/1.jpg', seq: 1, capturedAt: 100),
          _item(path: '/Photos/2.jpg', seq: 2, capturedAt: 300),
          _item(path: '/Photos/3.jpg', seq: 3, capturedAt: 200),
          _item(path: '/Photos/4.jpg', seq: 4, capturedAt: 400),
          _item(path: '/Photos/5.jpg', seq: 5, capturedAt: 50),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 5,
      ));

      final firstPage = await mirror.queryPage(offset: 0, limit: 2);
      expect(firstPage.items.map((i) => i.path),
          ['/Photos/4.jpg', '/Photos/2.jpg']);
      expect(firstPage.totalCount, 5);

      final secondPage = await mirror.queryPage(offset: 2, limit: 2);
      expect(secondPage.items.map((i) => i.path),
          ['/Photos/3.jpg', '/Photos/1.jpg']);
      expect(secondPage.totalCount, 5);

      final thirdPage = await mirror.queryPage(offset: 4, limit: 2);
      expect(thirdPage.items.map((i) => i.path), ['/Photos/5.jpg']);
      expect(thirdPage.totalCount, 5);
    });

    test('querying the mirror needs no network - it is a plain local query',
        () async {
      // No Dio/HTTP object exists anywhere in this test file; GalleryMirror
      // is constructed from nothing but the database. This test exists to
      // make that property explicit at the seam, not just implicit in the
      // class's dependencies.
      await mirror.applyPage(GalleryDeltaResponse(
        items: [_item(path: '/Photos/a.jpg', seq: 1, capturedAt: 100)],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));

      final page = await mirror.queryPage();
      expect(page.items, hasLength(1));
    });

    // Ticket 30: the two persisted watermarks GalleryGridController's sync
    // cadence reads and writes - covered here at the mirror seam directly,
    // independent of the controller logic that consumes them.
    group('sync cadence watermarks (ticket 30)', () {
      test('lastFullScanAt defaults to 0 - "no full scan has ever run"',
          () async {
        expect(await mirror.lastFullScanAt(), 0);
      });

      test('recordFullScanAt persists and is read back by lastFullScanAt',
          () async {
        await mirror.recordFullScanAt(123456);
        expect(await mirror.lastFullScanAt(), 123456);

        // A later call overwrites rather than accumulating a second row.
        await mirror.recordFullScanAt(999999);
        expect(await mirror.lastFullScanAt(), 999999);
      });

      test('lastSyncedAt defaults to 0 - "no sync has ever completed"',
          () async {
        expect(await mirror.lastSyncedAt(), 0);
      });

      test('recordSyncedAt persists and is read back by lastSyncedAt',
          () async {
        await mirror.recordSyncedAt(42);
        expect(await mirror.lastSyncedAt(), 42);

        await mirror.recordSyncedAt(84);
        expect(await mirror.lastSyncedAt(), 84);
      });

      test(
          'the full-scan and sync-throttle watermarks are independent of '
          'each other and of the delta feed\'s own cursor', () async {
        await mirror.applyPage(GalleryDeltaResponse(
          items: [_item(path: '/Photos/a.jpg', seq: 1, capturedAt: 100)],
          nextCursor: '',
          hasMore: false,
          nextSince: 7,
        ));
        await mirror.recordFullScanAt(111);
        await mirror.recordSyncedAt(222);

        expect(await mirror.since(), 7);
        expect(await mirror.lastFullScanAt(), 111);
        expect(await mirror.lastSyncedAt(), 222);
      });
    });
  });
}
