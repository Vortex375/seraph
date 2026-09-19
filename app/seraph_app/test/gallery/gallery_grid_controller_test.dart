import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:seraph_app/src/gallery/gallery_grid_controller.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
import 'package:seraph_app/src/gallery/local/local_scan_service.dart';
import 'package:seraph_app/src/gallery/local/local_source.dart';
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

    test('a failing sync leaves the gallery working from what the mirror holds',
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

    test('opening does not wait for the delta feed', () async {
      await populateMirror(db, count: 4);

      // A server that never answers - the worst case of the first launch
      // after an update, when the whole gallery could look like it needs
      // re-fetching. The view must be painting from the mirror long before
      // this resolves.
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        // deliberately never calls the handler
      }));
      final sync = GallerySyncService(
        FakeSettingsController(),
        FakeLoginController(),
        mirror,
        dio: dio,
      );

      final controller =
          GalleryGridController(mirror: mirror, syncService: sync);
      await controller.open().timeout(const Duration(seconds: 5));

      expect(controller.isLoading.value, isFalse);
      expect(controller.totalCount.value, 4);
      expect(controller.itemAt(0), isNotNull);
      expect(controller.isSyncing.value, isTrue,
          reason: 'the poll is still out there; the gallery did not wait');
    });

    test('a page arriving does not change the item count', () async {
      await populateMirror(db, count: 500);

      final controller = GalleryGridController(mirror: mirror, pageSize: 100);
      await controller.open();

      final countAtOpen = controller.totalCount.value;
      expect(countAtOpen, 500);

      // Deep in the collection: nothing is loaded there yet.
      expect(controller.itemAt(450), isNull);
      expect(controller.totalCount.value, countAtOpen,
          reason: 'asking for an unloaded index must not move the list length');

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

      // itemAt(200) schedules a page read of its own (it is unloaded, like
      // any other unloaded index) - drain it before teardown closes the
      // database, rather than leaving it to race db.close().
      await pumpEventQueue();
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

    test('the scrubber can ask for a date without loading that page', () async {
      const day = 24 * 60 * 60;
      await populateMirror(db, count: 400, newestCapturedAt: 1770000000);

      final controller = GalleryGridController(mirror: mirror, pageSize: 100);
      await controller.open();

      // Item 350 is 350 days before the newest one, and its page is nowhere
      // near loaded. The date now comes synchronously from the boundary map
      // built on reload - no await, no async lookup. knownDateAt returns
      // month granularity, so derive the expected month with the same local
      // conversion the controller uses.
      final date = controller.knownDateAt(350);
      expect(date, isNotNull);
      final expectedCapturedAt = 1770000000 - 350 * day;
      final expectedLocal =
          DateTime.fromMillisecondsSinceEpoch(expectedCapturedAt * 1000);
      expect(date!.year, expectedLocal.year);
      expect(date.month, expectedLocal.month);

      // Knowing the date did not require loading the page it lives on.
      expect(controller.itemAt(351), isNull);

      // itemAt(351) schedules a page read of its own - drain it before
      // teardown closes the database, rather than leaving it to race
      // db.close().
      await pumpEventQueue();
    });

    test('dates from a loaded page match the mirror order', () async {
      await populateMirror(db, count: 30);

      final controller = GalleryGridController(mirror: mirror);
      await controller.open();

      final expected = await mirrorInOrder(mirror);
      for (var i = 0; i < expected.length; i++) {
        final known = controller.knownDateAt(i);
        expect(known, isNotNull, reason: 'index $i');
        expect(known!.year, expected[i].capturedAtDateTime.year,
            reason: 'index $i');
        expect(known.month, expected[i].capturedAtDateTime.month,
            reason: 'index $i');
      }
    });

    test('a date beyond the end of the gallery is null, not an error',
        () async {
      await populateMirror(db, count: 3);

      final controller = GalleryGridController(mirror: mirror);
      await controller.open();

      expect(controller.knownDateAt(3), isNull);
      expect(controller.knownDateAt(-1), isNull);
    });

    // The boundary map is built in the device's LOCAL time (the same
    // conversion the label uses), not UTC - so a photo taken just past
    // midnight local on the first of a new month is labelled as that new
    // month, not the previous one. The expected months are derived from the
    // same local conversion the controller uses, so the test is correct
    // regardless of the test machine's timezone.
    test('a photo just past midnight local on a new month is grouped into it',
        () async {
      // Pick an epoch-second value that, in local time, falls on the first
      // of some month just after midnight, and another a day earlier in the
      // previous month. Derive everything from the same conversion.
      final justPastMidnight = DateTime(2026, 3, 1, 0, 30, 0);
      final previousDay = justPastMidnight.subtract(const Duration(days: 1));
      final justPastMidnightEpoch = justPastMidnight.millisecondsSinceEpoch ~/ 1000;
      final previousDayEpoch = previousDay.millisecondsSinceEpoch ~/ 1000;

      // Newer first: the just-past-midnight item is at index 0, the previous
      // month's item at index 1.
      await insertMirrorItem(db,
          path: '/Photos/new-month.jpg', capturedAt: justPastMidnightEpoch);
      await insertMirrorItem(db,
          path: '/Photos/prev-month.jpg', capturedAt: previousDayEpoch);

      final controller = GalleryGridController(mirror: mirror);
      await controller.open();
      await pumpEventQueue();

      final newMonthDate = controller.knownDateAt(0);
      final prevMonthDate = controller.knownDateAt(1);
      expect(newMonthDate, isNotNull);
      expect(prevMonthDate, isNotNull);
      // The just-past-midnight item is the new month, NOT the previous one -
      // proving the boundary is local, not UTC.
      expect(newMonthDate!.year, justPastMidnight.year);
      expect(newMonthDate.month, justPastMidnight.month);
      expect(prevMonthDate!.year, previousDay.year);
      expect(prevMonthDate.month, previousDay.month);
      expect(galleryMonthLabel(newMonthDate) != galleryMonthLabel(prevMonthDate),
          isTrue,
          reason: 'the two items must fall in different months locally');
    });

    test('a sync that adds items is picked up by an explicit reload', () async {
      await populateMirror(db, count: 2);

      final controller = GalleryGridController(mirror: mirror);
      await controller.open();
      expect(controller.totalCount.value, 2);

      await insertMirrorItem(db,
          path: '/Photos/newest.jpg', capturedAt: 1 << 31);

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

    test('open() also runs a Local Source scan alongside the cloud sync',
        () async {
      final source =
          FakeLocalSource([localMediaItem(displayName: 'device.jpg')]);
      final controller = GalleryGridController(
        mirror: mirror,
        localScanService: LocalScanService(mirror, localSource: source),
      );

      await controller.open();
      await pumpEventQueue();

      expect(source.scanCount, 1);
      expect(controller.totalCount.value, 1);
      expect(
          controller.itemAt(0)!.availability, GalleryAvailability.deviceOnly);
    });

    test('a failing local scan does not stop the gallery or the cloud sync',
        () async {
      await populateMirror(db, count: 2);

      final failingSource = _ThrowingLocalSource();
      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'items': <Map<String, dynamic>>[],
            'nextCursor': '',
            'hasMore': false,
            'nextSince': 0,
          },
        ));
      }));
      final sync = GallerySyncService(
        FakeSettingsController(),
        FakeLoginController(),
        mirror,
        dio: dio,
      );

      final controller = GalleryGridController(
        mirror: mirror,
        syncService: sync,
        localScanService: LocalScanService(mirror, localSource: failingSource),
      );

      await controller.open();
      await pumpEventQueue();

      expect(controller.syncError.value, isNull,
          reason: 'the cloud sync succeeded independently of the local scan');
      expect(controller.totalCount.value, 2,
          reason: 'the mirror still holds what it had before the failure');
    });

    // Ticket 17: the content-observer trigger, wired through open()/onClose.
    test(
        'a content-observer notification eventually shows a newly taken '
        'photo without a manual reload', () async {
      final source = FakeLocalSource()
        ..incrementalItems = [
          localMediaItem(
              displayName: 'just-taken.jpg', size: 7, dateTakenMillis: 20000),
        ];
      final controller = GalleryGridController(
        mirror: mirror,
        localScanService: LocalScanService(
          mirror,
          localSource: source,
          debounce: const Duration(milliseconds: 5),
        ),
      );

      await controller.open();
      await pumpEventQueue();
      expect(controller.totalCount.value, 0);

      source.emitChange();
      await Future.delayed(const Duration(milliseconds: 30));
      await pumpEventQueue();

      expect(controller.totalCount.value, 1,
          reason: 'ticket 17: taking a photo makes it appear within seconds '
              'while the app is running');
      expect(
          controller.itemAt(0)!.availability, GalleryAvailability.deviceOnly);
    });

    test('onClose releases the content-observer subscription', () async {
      final source = FakeLocalSource();
      final scanService = LocalScanService(
        mirror,
        localSource: source,
        debounce: const Duration(milliseconds: 5),
      );
      final controller = GalleryGridController(
        mirror: mirror,
        localScanService: scanService,
      );

      await controller.open();
      await pumpEventQueue();
      controller.onClose();

      source.emitChange();
      await Future.delayed(const Duration(milliseconds: 30));
      await pumpEventQueue();

      expect(source.incrementalScanCount, 0,
          reason: 'a closed controller must not leave a live subscription '
              'behind it');
    });

    test('the filter restricts totalCount and itemAt without reordering',
        () async {
      final source = FakeLocalSource([
        localMediaItem(
            displayName: 'device-only.jpg', size: 1, dateTakenMillis: 10000),
      ]);
      final controller = GalleryGridController(
        mirror: mirror,
        localScanService: LocalScanService(mirror, localSource: source),
      );
      await insertMirrorItem(db, path: '/Photos/cloud.jpg', capturedAt: 500);

      await controller.open();
      await pumpEventQueue();
      expect(controller.totalCount.value, 2);

      await controller.setFilter(GalleryAvailabilityFilter.notBackedUp);
      expect(controller.totalCount.value, 1);
      expect(
          controller.itemAt(0)!.availability, GalleryAvailability.deviceOnly);

      await controller.setFilter(GalleryAvailabilityFilter.cloudOnly);
      expect(controller.totalCount.value, 1);
      expect(controller.itemAt(0)!.path, '/Photos/cloud.jpg');

      await controller.setFilter(GalleryAvailabilityFilter.all);
      expect(controller.totalCount.value, 2);
    });

    test('the summary reports backed-up and not-backed-up counts', () async {
      final source = FakeLocalSource([
        localMediaItem(
            displayName: 'device-only.jpg', size: 1, dateTakenMillis: 10000),
      ]);
      final controller = GalleryGridController(
        mirror: mirror,
        localScanService: LocalScanService(mirror, localSource: source),
      );
      await insertMirrorItem(db, path: '/Photos/cloud.jpg', capturedAt: 500);

      await controller.open();
      await pumpEventQueue();

      expect(controller.summary.value.deviceOnly, 1);
      expect(controller.summary.value.cloudOnly, 1);
      expect(controller.summary.value.backedUp, 1);
      expect(controller.summary.value.notBackedUp, 1);
    });

    // Ticket 16's mirror-seam criterion: drive a fake Local Source through
    // each grant state and assert on what the gallery reports about
    // coverage, rather than on any widget.
    group('local photo-access grant (ticket 16)', () {
      test('with no Local Source at all, the grant is unsupported', () async {
        final controller = GalleryGridController(mirror: mirror);
        await controller.open();

        expect(controller.localPermission.value,
            LocalPermissionStatus.unsupported);
      });

      test('a full grant is reported as granted', () async {
        final source = FakeLocalSource([], LocalPermissionStatus.granted);
        final controller = GalleryGridController(
          mirror: mirror,
          localScanService: LocalScanService(mirror, localSource: source),
        );

        await controller.open();
        await pumpEventQueue();

        expect(controller.localPermission.value, LocalPermissionStatus.granted);
      });

      test(
          'a partial grant is reported as partial, distinct from an empty '
          'selection meaning denied', () async {
        final source = FakeLocalSource(
          const [], // the user selected zero photos so far
          LocalPermissionStatus.partial,
        );
        final controller = GalleryGridController(
          mirror: mirror,
          localScanService: LocalScanService(mirror, localSource: source),
        );

        await controller.open();
        await pumpEventQueue();

        expect(controller.localPermission.value, LocalPermissionStatus.partial,
            reason: 'zero visible photos under a partial grant must not be '
                'mistaken for denial - the grant, not the item count, is '
                'the source of truth');
      });

      test('a denied grant leaves the cloud-only gallery fully intact',
          () async {
        await insertMirrorItem(db, path: '/Photos/cloud.jpg', capturedAt: 500);
        final source = FakeLocalSource(const [], LocalPermissionStatus.denied);
        final controller = GalleryGridController(
          mirror: mirror,
          localScanService: LocalScanService(mirror, localSource: source),
        );

        await controller.open();
        await pumpEventQueue();

        expect(controller.localPermission.value, LocalPermissionStatus.denied);
        expect(controller.totalCount.value, 1,
            reason: 'the cloud item is unaffected by a denied device grant');
        expect(
            controller.itemAt(0)!.availability, GalleryAvailability.cloudOnly);
      });

      test(
          'requestLocalPermission asks the source, applies the new grant and '
          'syncs immediately', () async {
        final source = FakeLocalSource(const [], LocalPermissionStatus.denied);
        final controller = GalleryGridController(
          mirror: mirror,
          localScanService: LocalScanService(mirror, localSource: source),
        );
        await controller.open();
        await pumpEventQueue();
        expect(controller.localPermission.value, LocalPermissionStatus.denied);

        source.setItems([localMediaItem(displayName: 'newly-granted.jpg')]);
        source.nextRequestResult = LocalPermissionStatus.granted;

        await controller.requestLocalPermission();

        expect(source.requestCount, 1);
        expect(controller.localPermission.value, LocalPermissionStatus.granted);
        expect(controller.totalCount.value, 1,
            reason: 'the newly visible photo is scanned in immediately, not '
                'on the next unrelated sync');
      });

      test('openLocalPermissionSettings reaches the source', () async {
        final source = FakeLocalSource(const [], LocalPermissionStatus.partial);
        final controller = GalleryGridController(
          mirror: mirror,
          localScanService: LocalScanService(mirror, localSource: source),
        );
        await controller.open();
        await pumpEventQueue();

        await controller.openLocalPermissionSettings();

        expect(source.openSettingsCount, 1);
      });

      test(
          'a grant that widens between two syncs (picked up without a '
          'restart) is reflected the moment the running controller re-syncs',
          () async {
        final source = FakeLocalSource(
          const [], // nothing selected yet
          LocalPermissionStatus.partial,
        );
        final controller = GalleryGridController(
          mirror: mirror,
          localScanService: LocalScanService(mirror, localSource: source),
        );
        await controller.open();
        await pumpEventQueue();
        expect(controller.localPermission.value, LocalPermissionStatus.partial);
        expect(controller.totalCount.value, 0);

        // The user left the app, granted full access in system Settings, and
        // came back - simulated here as the fake's state changing under the
        // same running controller instance, then [syncOnResume] - what
        // GalleryView's resume handler actually calls (ticket 30's throttle
        // is why it is this and not [syncNow] directly; see the next group).
        source.setPermissionStatus(LocalPermissionStatus.granted);
        source.setItems([localMediaItem(displayName: 'was-restricted.jpg')]);

        await controller.syncOnResume();

        expect(controller.localPermission.value, LocalPermissionStatus.granted);
        expect(controller.totalCount.value, 1);
      });
    });

    // Ticket 30: opening/resuming the gallery no longer blocks on a full
    // sync every time - a throttle skips a redundant re-sync entirely, and
    // the interactive path runs the cheaper incremental scan except on a
    // cold start, past a backstop interval, or when a caller forces one.
    group('sync cadence (ticket 30)', () {
      test(
          'a second syncNow() within the throttle window is a no-op: no '
          'HTTP request, no media-store call, no spinner', () async {
        await populateMirror(db, count: 1);
        var httpCalls = 0;
        final dio = Dio();
        dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
          httpCalls++;
          handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'items': <Map<String, dynamic>>[],
              'nextCursor': '',
              'hasMore': false,
              'nextSince': 0,
            },
          ));
        }));
        final sync = GallerySyncService(
          FakeSettingsController(),
          FakeLoginController(),
          mirror,
          dio: dio,
        );
        final source = FakeLocalSource();
        final clock = FakeClock();
        final controller = GalleryGridController(
          mirror: mirror,
          syncService: sync,
          localScanService: LocalScanService(mirror, localSource: source),
          now: clock.call,
        );

        await controller.open();
        await pumpEventQueue();
        expect(httpCalls, 1);
        expect(source.scanCount, 1);

        // No time passed at all - well inside the 60-second throttle.
        await controller.syncNow();

        expect(httpCalls, 1, reason: 'throttled: no second HTTP request');
        expect(source.scanCount, 1, reason: 'throttled: no second full scan');
        expect(source.incrementalScanCount, 0,
            reason: 'throttled: not even an incremental scan');
        expect(controller.isSyncing.value, isFalse,
            reason: 'throttled: the spinner never turns on');
      });

      test(
          'an unforced syncNow() past the throttle window runs an '
          'incremental scan, not a full one', () async {
        final source = FakeLocalSource([localMediaItem(displayName: 'a.jpg')]);
        final clock = FakeClock();
        final controller = GalleryGridController(
          mirror: mirror,
          localScanService: LocalScanService(mirror, localSource: source),
          now: clock.call,
        );
        await controller.open();
        await pumpEventQueue();
        expect(source.scanCount, 1,
            reason: 'cold start always runs a full scan');

        // Past the 60-second throttle, nowhere near the 6-hour backstop.
        clock.advance(const Duration(minutes: 2));
        await controller.syncNow();

        expect(source.scanCount, 1,
            reason: 'a recent full scan means this sync must be incremental');
        expect(source.incrementalScanCount, 1);
      });

      test(
          'a full scan runs again once the backstop interval has passed, '
          'even without force', () async {
        final source = FakeLocalSource([localMediaItem(displayName: 'a.jpg')]);
        final clock = FakeClock();
        final controller = GalleryGridController(
          mirror: mirror,
          localScanService: LocalScanService(mirror, localSource: source),
          now: clock.call,
        );
        await controller.open();
        await pumpEventQueue();
        expect(source.scanCount, 1);

        clock.advance(const Duration(hours: 6, minutes: 1));
        await controller.syncNow();

        expect(source.scanCount, 2,
            reason: 'the backstop interval forces a full scan even when the '
                'caller did not ask for one');
      });

      test('a permission change picked up on resume defeats the throttle',
          () async {
        final source = FakeLocalSource(const [], LocalPermissionStatus.denied);
        final clock = FakeClock();
        final controller = GalleryGridController(
          mirror: mirror,
          localScanService: LocalScanService(mirror, localSource: source),
          now: clock.call,
        );
        await controller.open();
        await pumpEventQueue();
        expect(controller.localPermission.value, LocalPermissionStatus.denied);

        // Well inside the throttle window - the user left the app, granted
        // access in system Settings, and came straight back.
        clock.advance(const Duration(seconds: 5));
        source.setPermissionStatus(LocalPermissionStatus.granted);
        source
            .setItems([localMediaItem(displayName: 'granted-while-away.jpg')]);

        await controller.syncOnResume();

        expect(controller.localPermission.value, LocalPermissionStatus.granted);
        expect(controller.totalCount.value, 1,
            reason: 'a permission change on resume must defeat the throttle, '
                'not be swallowed by it');
        expect(source.scanCount, 2,
            reason: 'a permission change on resume also forces a full scan, '
                'not just bypasses the throttle');
      });

      test(
          'a resume with no permission change is throttled exactly like any '
          'other syncNow() call', () async {
        final source = FakeLocalSource(const [], LocalPermissionStatus.granted);
        final clock = FakeClock();
        final controller = GalleryGridController(
          mirror: mirror,
          localScanService: LocalScanService(mirror, localSource: source),
          now: clock.call,
        );
        await controller.open();
        await pumpEventQueue();
        expect(source.scanCount, 1);

        clock.advance(const Duration(seconds: 5));
        await controller.syncOnResume();

        expect(source.scanCount, 1,
            reason: 'no grant change: the throttle applies exactly as it '
                'would to any other resume');
        expect(source.incrementalScanCount, 0,
            reason: 'the throttled call never even reaches the incremental '
                'scan path');
      });
    });
  });
}

class _ThrowingLocalSource implements LocalSource {
  @override
  Future<List<LocalMediaItem>> fullScan() {
    throw StateError('scan failed');
  }

  @override
  Future<LocalIncrementalScanResult> incrementalScan(int sinceGeneration) {
    throw StateError('incremental scan failed');
  }

  @override
  Future<int> currentGeneration() {
    throw StateError('currentGeneration failed');
  }

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  Future<LocalPermissionStatus> permissionStatus() async =>
      LocalPermissionStatus.granted;

  @override
  Future<LocalPermissionStatus> requestPermission() async =>
      LocalPermissionStatus.granted;

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<Uint8List?> loadThumbnail({
    required String relativePath,
    required String displayName,
    required int width,
    required int height,
  }) async =>
      null;

  @override
  Future<Uint8List?> loadOriginal({
    required String relativePath,
    required String displayName,
  }) async =>
      null;

  @override
  void dispose() {}
}
