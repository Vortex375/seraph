import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
import 'package:seraph_app/src/gallery/local/local_scan_service.dart';
import 'package:seraph_app/src/gallery/local/local_source.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_delta_models.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';

import '../gallery_test_support.dart';

/// Drives [LocalScanService] through a [FakeLocalSource] end to end - the
/// device-side twin of `gallery_sync_service_test.dart` - so the ticket 15
/// criterion "covered at the app's mirror seam with a fake Local Source,
/// including dedup between a device item and a cloud item" is exercised
/// through the actual seam callers use (a `LocalSource`), not just through
/// [GalleryMirror.applyLocalScan] directly.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LocalScanService', () {
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;

    setUp(() {
      db = GalleryMirrorDatabase(NativeDatabase.memory());
      mirror = GalleryMirror(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('a null Local Source makes scan() a no-op', () async {
      final service = LocalScanService(mirror, localSource: null);
      await service.scan();
      expect(await mirror.totalCount(), 0);
    });

    test('scanning a fake Local Source imports its photos as Device only',
        () async {
      final source = FakeLocalSource([
        localMediaItem(displayName: 'a.jpg', size: 111, dateTakenMillis: 1000000),
        localMediaItem(displayName: 'b.jpg', size: 222, dateTakenMillis: 2000000),
      ]);
      final service = LocalScanService(mirror, localSource: source);

      await service.scan();

      final items = await mirror.queryItems();
      expect(items, hasLength(2));
      expect(items.every((i) => i.availability == GalleryAvailability.deviceOnly),
          isTrue);
      expect(source.scanCount, 1);
    });

    test(
        'a device item from the fake source dedups with a cloud item already '
        'in the mirror', () async {
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          const GalleryDeltaItem(
            providerId: 'space-a',
            path: '/Photos/holiday.jpg',
            seq: 1,
            tombstone: false,
            capturedAt: 42000,
            size: 555,
          ),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));

      final source = FakeLocalSource([
        localMediaItem(
          displayName: 'holiday.jpg',
          size: 555, // matches the cloud item
          dateTakenMillis: 42000 * 1000, // matches its Capture Date
        ),
      ]);
      final service = LocalScanService(mirror, localSource: source);

      await service.scan();

      final items = await mirror.queryItems();
      expect(items, hasLength(1),
          reason: 'the same photo on the device and in Seraph must appear '
              'exactly once');
      expect(items.single.availability, GalleryAvailability.synced);
      expect(items.single.path, '/Photos/holiday.jpg');
    });

    test('re-scanning the same photos twice does not duplicate them',
        () async {
      final source = FakeLocalSource([
        localMediaItem(displayName: 'a.jpg', size: 111, dateTakenMillis: 1000000),
      ]);
      final service = LocalScanService(mirror, localSource: source);

      await service.scan();
      await service.scan();

      expect(await mirror.totalCount(), 1);
      expect(source.scanCount, 2);
    });

    // Ticket 16: the permission pass-through methods, at the same seam.
    group('permission pass-through', () {
      test('with no Local Source, permissionStatus is unsupported', () async {
        final service = LocalScanService(mirror, localSource: null);
        expect(
            await service.permissionStatus(), LocalPermissionStatus.unsupported);
      });

      test('with no Local Source, requestPermission is unsupported and a '
          'no-op', () async {
        final service = LocalScanService(mirror, localSource: null);
        expect(
            await service.requestPermission(), LocalPermissionStatus.unsupported);
      });

      test('with no Local Source, openAppSettings is a no-op', () async {
        final service = LocalScanService(mirror, localSource: null);
        await service.openAppSettings(); // must not throw
      });

      test('permissionStatus reads straight through to the source', () async {
        final source =
            FakeLocalSource(const [], LocalPermissionStatus.partial);
        final service = LocalScanService(mirror, localSource: source);

        expect(await service.permissionStatus(), LocalPermissionStatus.partial);
      });

      test('requestPermission reads the source\'s answer straight through',
          () async {
        final source = FakeLocalSource(const [], LocalPermissionStatus.denied)
          ..nextRequestResult = LocalPermissionStatus.granted;
        final service = LocalScanService(mirror, localSource: source);

        expect(await service.requestPermission(), LocalPermissionStatus.granted);
        expect(source.requestCount, 1);
      });

      test('openAppSettings reaches the source', () async {
        final source = FakeLocalSource();
        final service = LocalScanService(mirror, localSource: source);

        await service.openAppSettings();

        expect(source.openSettingsCount, 1);
      });
    });

    // Ticket 17: the generation-based incremental scan and its watermark.
    group('incremental scan', () {
      test('scan() primes the watermark at the source\'s current generation',
          () async {
        final source = FakeLocalSource()..generation = 500;
        final service = LocalScanService(mirror, localSource: source);

        await service.scan();

        expect(await mirror.localGeneration(), 500);
      });

      test(
          'incrementalScan() reads the persisted watermark and applies only '
          'what the source reports changed since it', () async {
        final source = FakeLocalSource()..generation = 100;
        final service = LocalScanService(mirror, localSource: source);
        await service.scan(); // primes the watermark at 100

        source.generation = 250;
        source.incrementalItems = [
          localMediaItem(
              displayName: 'new.jpg', size: 999, dateTakenMillis: 5000000),
        ];

        await service.incrementalScan();

        expect(source.incrementalScanSinceCalls, [100],
            reason: 'the fast path must ask for what changed since the last '
                'watermark, not replay the whole library');
        final items = await mirror.queryItems();
        expect(items, hasLength(1));
        expect(
            items.single.availability, GalleryAvailability.deviceOnly);
        expect(await mirror.localGeneration(), 250);
      });

      test(
          'incrementalScan() never removes a row missing from its batch - '
          'only a full scan may do that', () async {
        final source = FakeLocalSource([
          localMediaItem(displayName: 'a.jpg', size: 1, dateTakenMillis: 1000),
        ]);
        final service = LocalScanService(mirror, localSource: source);
        await service.scan();
        expect(await mirror.totalCount(), 1);

        // Nothing in this incremental batch mentions "a.jpg" at all - a
        // real incremental scan reporting zero changes since the watermark.
        source.incrementalItems = const [];
        await service.incrementalScan();

        expect(await mirror.totalCount(), 1,
            reason: 'an incremental scan must never delete what it did not '
                'even look at - deletion detection needs the whole '
                "library's current state, which only a full scan has");
      });

      test(
          'the watermark survives across a new LocalScanService instance '
          'sharing the same mirror - i.e. an app restart', () async {
        final source = FakeLocalSource()..generation = 777;
        final firstRun = LocalScanService(mirror, localSource: source);
        await firstRun.scan();

        // A brand new service instance, as if the app had been killed and
        // relaunched - only the mirror's own database (never in-process
        // state) can be what the second instance resumes from.
        final secondRun = LocalScanService(mirror, localSource: source);
        await secondRun.incrementalScan();

        expect(source.incrementalScanSinceCalls, [777]);
      });

      test(
          'a photo added while the app was not running is picked up by the '
          'next full scan, independent of the incremental path entirely',
          () async {
        final source = FakeLocalSource();
        final service = LocalScanService(mirror, localSource: source);
        await service.scan();
        expect(await mirror.totalCount(), 0);

        // The photo "appeared" while nothing was scanning - a fresh
        // fullScan() result is all the next scan() (an app-start scan) has
        // to go on, exactly like a cold app launch.
        source.setItems([
          localMediaItem(
              displayName: 'while-closed.jpg', size: 654, dateTakenMillis: 6000),
        ]);
        await service.scan();

        expect(await mirror.totalCount(), 1);
      });
    });

    // Ticket 17: the content-observer trigger and its debouncing.
    group('content-observer trigger', () {
      test(
          'a change notification runs a debounced incremental scan and '
          'notifies the caller once the mirror has been updated', () async {
        final source = FakeLocalSource()
          ..incrementalItems = [
            localMediaItem(
                displayName: 'burst.jpg', size: 42, dateTakenMillis: 9000),
          ];
        final service = LocalScanService(
          mirror,
          localSource: source,
          debounce: const Duration(milliseconds: 5),
        );
        var notified = 0;
        service.watchForChanges(() => notified++);

        source.emitChange();
        await Future.delayed(const Duration(milliseconds: 30));
        await pumpEventQueue();

        expect(source.incrementalScanCount, 1);
        expect(notified, 1);
        expect(await mirror.totalCount(), 1,
            reason: 'this is what "taking a photo appears within seconds" '
                'means at this seam: a trigger leads to an applied scan');
      });

      test(
          'a burst of many rapid notifications collapses into a single '
          'incremental scan, not one per notification', () async {
        final source = FakeLocalSource();
        final service = LocalScanService(
          mirror,
          localSource: source,
          debounce: const Duration(milliseconds: 20),
        );
        service.watchForChanges(() {});

        for (var i = 0; i < 20; i++) {
          source.emitChange();
        }
        await Future.delayed(const Duration(milliseconds: 80));
        await pumpEventQueue();

        expect(source.incrementalScanCount, 1,
            reason: 'a burst of notifications must not turn into a storm of '
                'scans');
      });

      test(
          'stopWatchingForChanges cancels the subscription - no scan runs '
          'for a notification delivered afterwards', () async {
        final source = FakeLocalSource();
        final service = LocalScanService(
          mirror,
          localSource: source,
          debounce: const Duration(milliseconds: 5),
        );
        service.watchForChanges(() {});
        service.stopWatchingForChanges();

        source.emitChange();
        await Future.delayed(const Duration(milliseconds: 20));
        await pumpEventQueue();

        expect(source.incrementalScanCount, 0,
            reason: 'a released subscription must not leak a live scan '
                'trigger past it');
      });

      test(
          'suppressing every content-observer notification still leaves the '
          'gallery eventually correct - latency is the only casualty, never '
          'correctness', () async {
        final source = FakeLocalSource();
        final service = LocalScanService(
          mirror,
          localSource: source,
          debounce: const Duration(milliseconds: 5),
        );

        // The governing rule, under direct test: watchForChanges() is never
        // called at all, so `source.changes` has no subscriber and every
        // notification the platform could ever send is silently dropped -
        // this simulates "not a single content-observer notification ever
        // arrives" as literally as a test can. The only way this photo can
        // reach the mirror is an explicit scan, exactly what a periodic or
        // app-start full scan is - never the observer.
        source.setItems([
          localMediaItem(
              displayName: 'never-notified.jpg',
              size: 321,
              dateTakenMillis: 8000),
        ]);

        expect(await mirror.totalCount(), 0,
            reason: 'nothing has run yet, and the fake never emits a change '
                'notification on its own');

        await service.scan();

        expect(await mirror.totalCount(), 1,
            reason: 'a full scan alone - with zero notifications ever '
                'delivered, ever - must still make the gallery correct');
        expect(source.incrementalScanCount, 0,
            reason: 'correctness here came entirely from scan(), not from '
                'any notification-driven path');
      });
    });

    // The lifecycle this fix makes explicit: releasing the Local Source
    // must not be left implicit in the singleton's app-lifetime existence.
    group('dispose', () {
      test('stops watching for changes and releases the Local Source',
          () async {
        final source = FakeLocalSource();
        final service = LocalScanService(
          mirror,
          localSource: source,
          debounce: const Duration(milliseconds: 5),
        );
        service.watchForChanges(() {});

        service.dispose();

        expect(source.disposeCount, 1);

        // A notification arriving after dispose must not trigger a scan -
        // stopWatchingForChanges's own subscription-release guarantee,
        // still upheld once folded into dispose().
        source.emitChange();
        await Future.delayed(const Duration(milliseconds: 20));
        await pumpEventQueue();
        expect(source.incrementalScanCount, 0);
      });

      test('is safe to call more than once', () async {
        final source = FakeLocalSource();
        final service = LocalScanService(mirror, localSource: source);

        service.dispose();
        service.dispose();

        expect(source.disposeCount, 2,
            reason: 'the source itself decides how to handle repeat '
                'disposal - LocalScanService just always forwards the call');
      });

      test('is a no-op with no Local Source', () async {
        final service = LocalScanService(mirror, localSource: null);
        expect(() => service.dispose(), returnsNormally);
      });
    });
  });
}
