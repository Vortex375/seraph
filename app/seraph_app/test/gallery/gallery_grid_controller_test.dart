import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:seraph_app/src/gallery/gallery_grid_controller.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_sync_service.dart';

import 'gallery_test_support.dart';

/// Ticket 13 requires gallery logic to be verified at the mirror seam rather
/// than through widgets, so these tests drive [GalleryGridController] - the
/// thing that decides what the grid and the viewer show, in what order, and
/// how much of it - directly against a pre-populated mirror.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GalleryGridController', () {
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;

    setUp(() {
      Get.testMode = true;
      db = openTestMirrorDatabase();
      mirror = GalleryMirror(db);
    });

    tearDown(() async {
      await db.close();
      Get.reset();
    });

    test('opens on the mirror in Capture Date order, newest first', () async {
      await insertMirrorItem(db, path: '/Photos/old.jpg', capturedAt: 100);
      await insertMirrorItem(db, path: '/Photos/new.jpg', capturedAt: 300);
      await insertMirrorItem(db, path: '/Photos/mid.jpg', capturedAt: 200);

      final controller = GalleryGridController(mirror: mirror);
      await controller.open();

      expect(controller.isLoading.value, isFalse);
      expect(controller.totalCount.value, 3);
      expect(controller.itemAt(0)!.path, '/Photos/new.jpg');
      expect(controller.itemAt(1)!.path, '/Photos/mid.jpg');
      expect(controller.itemAt(2)!.path, '/Photos/old.jpg');
    });

    test('opening needs no network at all', () async {
      await populateMirror(db, count: 5);

      // No sync service, therefore nothing that could reach a server. The
      // gallery still opens and still has its items - this is the offline
      // case, and it is the ordinary case too.
      final controller = GalleryGridController(mirror: mirror);
      await controller.open();

      expect(controller.totalCount.value, 5);
      expect(controller.itemAt(0), isNotNull);
      expect(controller.syncError.value, isNull);
    });

    test(
        'a failing sync leaves the gallery working from what the mirror holds',
        () async {
      await populateMirror(db, count: 3);

      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        handler.reject(DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          message: 'no route to host',
        ));
      }));
      final sync = GallerySyncService(
        FakeSettingsController(),
        FakeLoginController(),
        mirror,
        dio: dio,
      );

      final controller =
          GalleryGridController(mirror: mirror, syncService: sync);
      // open() starts the poll but does not wait for it - the view must paint
      // from the mirror without waiting for the network. Give the poll a turn
      // to fail.
      await controller.open();
      await pumpEventQueue();

      expect(controller.syncError.value, isNotNull);
      expect(controller.totalCount.value, 3,
          reason: 'the mirror is the source of the list, not the network');
      expect(controller.itemAt(0), isNotNull);
    });

    test('a page arriving does not change the item count', () async {
      await populateMirror(db, count: 500);

      final controller =
          GalleryGridController(mirror: mirror, pageSize: 100);
      await controller.open();

      final countAtOpen = controller.totalCount.value;
      expect(countAtOpen, 500);

      // Deep in the collection: nothing is loaded there yet.
      expect(controller.itemAt(450), isNull);
      expect(controller.totalCount.value, countAtOpen,
          reason:
              'asking for an unloaded index must not move the list length');

      // Let the scheduled page read finish.
      await pumpEventQueue();

      expect(controller.itemAt(450), isNotNull);
      expect(controller.totalCount.value, countAtOpen,
          reason: 'a page arriving must not move the list length either');
    });

    test('pages are read on demand, not all at once', () async {
      await populateMirror(db, count: 500);

      final controller = GalleryGridController(mirror: mirror, pageSize: 100);
      await controller.open();

      // Only the first page is in memory after opening...
      expect(controller.itemAt(99), isNotNull);
      expect(controller.itemAt(100), isNull);

      // ...and asking for a range pulls in exactly the pages it spans.
      controller.ensureRangeLoaded(95, 105);
      await pumpEventQueue();

      expect(controller.itemAt(100), isNotNull);
      expect(controller.itemAt(199), isNotNull);
      expect(controller.itemAt(200), isNull);
    });

    test('an index outside the gallery is not a page read', () async {
      await populateMirror(db, count: 10);

      final controller = GalleryGridController(mirror: mirror);
      await controller.open();

      expect(controller.itemAt(10), isNull);
      expect(controller.itemAt(-1), isNull);
      await pumpEventQueue();
      expect(controller.totalCount.value, 10);
    });

    test('the scrubber can ask for a date without loading that page',
        () async {
      const day = 24 * 60 * 60;
      await populateMirror(db, count: 400, newestCapturedAt: 1770000000);

      final controller = GalleryGridController(mirror: mirror, pageSize: 100);
      await controller.open();

      // Item 350 is 350 days before the newest one, and its page is nowhere
      // near loaded.
      expect(controller.knownDateAt(350), isNull);

      final date = await controller.dateAt(350);
      expect(date, isNotNull);
      expect(date!.millisecondsSinceEpoch ~/ 1000, 1770000000 - 350 * day);

      // Knowing the date did not require loading the page it lives on.
      expect(controller.itemAt(351), isNull);
    });

    test('dates from a loaded page match the mirror order', () async {
      await populateMirror(db, count: 30);

      final controller = GalleryGridController(mirror: mirror);
      await controller.open();

      final expected = await mirrorInOrder(mirror);
      for (var i = 0; i < expected.length; i++) {
        expect(controller.knownDateAt(i), expected[i].capturedAtDateTime,
            reason: 'index $i');
      }
    });

    test('a date beyond the end of the gallery is null, not an error',
        () async {
      await populateMirror(db, count: 3);

      final controller = GalleryGridController(mirror: mirror);
      await controller.open();

      expect(await controller.dateAt(3), isNull);
      expect(await controller.dateAt(-1), isNull);
    });

    test('a sync that adds items is picked up by an explicit reload',
        () async {
      await populateMirror(db, count: 2);

      final controller = GalleryGridController(mirror: mirror);
      await controller.open();
      expect(controller.totalCount.value, 2);

      await insertMirrorItem(db, path: '/Photos/newest.jpg', capturedAt: 1 << 31);

      // Still 2 until asked - the count does not move under the user.
      expect(controller.totalCount.value, 2);

      await controller.reload();
      expect(controller.totalCount.value, 3);
      expect(controller.itemAt(0)!.path, '/Photos/newest.jpg');
    });

    test('a tombstoned item disappears from the list on reload', () async {
      await populateMirror(db, count: 3);

      final controller = GalleryGridController(mirror: mirror);
      await controller.open();
      expect(controller.totalCount.value, 3);

      await (db.delete(db.galleryItems)
            ..where((t) => t.path.equals('/Photos/photo-0.jpg')))
          .go();
      await controller.reload();

      expect(controller.totalCount.value, 2);
      expect(controller.itemAt(0)!.path, '/Photos/photo-1.jpg');
    });

    test('an empty gallery is an empty list, not a failure', () async {
      final controller = GalleryGridController(mirror: mirror);
      await controller.open();

      expect(controller.totalCount.value, 0);
      expect(controller.itemAt(0), isNull);
      expect(controller.isLoading.value, isFalse);
    });
  });
}
