import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
import 'package:seraph_app/src/gallery/local/local_source.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_delta_models.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_upload_backend.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_upload_service.dart';
import 'package:seraph_app/src/gallery/sync/gallery_sync_engine.dart';

import '../gallery_test_support.dart';

Uint8List _bytesOfLength(int length, [int fill = 0x42]) =>
    Uint8List.fromList(List<int>.filled(length, fill));

/// Ticket 22's own explicit coverage requirement: "covered at the app's
/// mirror seam by running the engine headlessly against a stubbed backend
/// and a fake Local Source, asserting on resulting mirror state" - exactly
/// [GallerySyncEngine], driven the same way its real headless-isolate
/// bootstrap (`gallery_data_sync_service_io.dart`) drives it, against
/// [FakeGalleryUploadBackend] and [FakeLocalSource].
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GallerySyncEngine.run', () {
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;
    late FakeGalleryUploadBackend backend;
    late FakeLocalSource localSource;
    late GalleryUploadService uploadService;

    // [GalleryMirror.applyLocalScan] is a FULL scan - it treats any local
    // identity absent from the list it is given as removed from the device
    // (that is what makes it ticket 15's correctness anchor). A test that
    // wants several device photos in the mirror at once therefore has to
    // scan them all together, not one call per photo - [scanDevicePhoto]
    // accumulates the whole device state across calls and re-applies it in
    // full each time, exactly as a real repeated Local Source scan would.
    // Reset in [setUp] alongside everything else - a `group`'s body runs
    // once, so a list declared here without resetting it per test would
    // leak scans from one test into the next test's fresh database.
    late List<LocalMediaItem> scannedItems;

    setUp(() async {
      db = GalleryMirrorDatabase(NativeDatabase.memory());
      mirror = GalleryMirror(db);
      backend = FakeGalleryUploadBackend();
      localSource = FakeLocalSource();
      uploadService = GalleryUploadService(mirror, backend, localSource);
      scannedItems = [];

      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
    });

    tearDown(() async {
      await db.close();
    });

    Future<GalleryItem> scanDevicePhoto({
      String relativePath = 'DCIM/Camera/',
      required String displayName,
      required int capturedAtSeconds,
      required Uint8List bytes,
      int? nowMillis,
    }) async {
      scannedItems.add(localMediaItem(
        relativePath: relativePath,
        displayName: displayName,
        size: bytes.length,
        dateTakenMillis: capturedAtSeconds * 1000,
      ));
      await mirror.applyLocalScan(scannedItems, nowMillis: nowMillis);
      localSource.setLocalBytes(relativePath, displayName, bytes);
      return (await mirror.queryItems())
          .firstWhere((i) => i.localDisplayName == displayName);
    }

    test('reports nothingToDo and writes a completed, all-zero SyncRunState '
        'when no photo is eligible for upload', () async {
      final engine = GallerySyncEngine(mirror, uploadService);

      final result = await engine.run();

      expect(result.outcome, GallerySyncOutcome.nothingToDo);
      expect(result.uploaded, 0);
      expect(result.failed, 0);

      final state = await mirror.syncRunState();
      expect(state.status, syncStatusCompleted);
      expect(state.totalItems, 0);
      expect(state.completedItems, 0);
      expect(state.totalBytes, 0);
    });

    test('uploads every Device only photo covered by an active Sync Pair, '
        'writing progress to SyncRunState as it goes, and never touches a '
        'photo no Sync Pair covers', () async {
      final covered1 = await scanDevicePhoto(
        displayName: 'IMG_0001.jpg',
        capturedAtSeconds: 1000,
        bytes: _bytesOfLength(1000),
      );
      final covered2 = await scanDevicePhoto(
        displayName: 'IMG_0002.jpg',
        capturedAtSeconds: 2000,
        bytes: _bytesOfLength(2000),
      );
      // Not under the Sync Pair's local folder at all - itemsPendingUpload
      // must never queue it, and the engine must never touch it. Kept under
      // `DCIM/` (rather than e.g. `Screenshots/`) so ticket 29's "only DCIM
      // is selected by default" rule does not ALSO hide it from
      // [GalleryMirror.queryItems] - this test is about Sync Pair coverage,
      // not Local Folder selection.
      await scanDevicePhoto(
        relativePath: 'DCIM/Other/',
        displayName: 'shot.png',
        capturedAtSeconds: 3000,
        bytes: _bytesOfLength(500),
      );

      final engine = GallerySyncEngine(mirror, uploadService);
      final result = await engine.run();

      expect(result.outcome, GallerySyncOutcome.completed);
      expect(result.uploaded, 2);
      expect(result.failed, 0);
      expect(backend.putCalls, hasLength(2));
      expect(
        backend.putCalls.map((c) => c.$2),
        containsAll([
          '/Photos/Phone/IMG_0001.jpg',
          '/Photos/Phone/IMG_0002.jpg',
        ]),
      );

      final items = await mirror.queryItems();
      final upload1 = items.firstWhere((i) => i.id == covered1.id);
      final upload2 = items.firstWhere((i) => i.id == covered2.id);
      expect(upload1.isAwaitingVerification, isTrue,
          reason: 'the engine records the upload but never marks Verified '
              'itself - only the delta feed can (ticket 20)');
      expect(upload2.isAwaitingVerification, isTrue);

      final uncovered = (await mirror.queryItems())
          .firstWhere((i) => i.localDisplayName == 'shot.png');
      expect(uncovered.availability, GalleryAvailability.deviceOnly);
      expect(uncovered.isAwaitingVerification, isFalse,
          reason: 'no Sync Pair covers it, so the engine must never attempt '
              'to upload it');

      final state = await mirror.syncRunState();
      expect(state.status, syncStatusCompleted);
      expect(state.totalItems, 2);
      expect(state.completedItems, 2);
      expect(state.failedItems, 0);
      expect(state.totalBytes, 3000);
      expect(state.completedBytes, 3000);
    });

    test('retries an item ticket 20 left needing a mismatch retry before '
        'starting on the fresh backlog', () async {
      // Upload one photo, then feed a contradicting length back through the
      // delta feed - exactly ticket 20's "real PUT, contradicted" case,
      // leaving the item in itemsNeedingUploadRetry.
      final uploaded = await scanDevicePhoto(
        displayName: 'IMG_0001.jpg',
        capturedAtSeconds: 1000,
        bytes: _bytesOfLength(4096),
      );
      await uploadService.upload(uploaded);
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          GalleryDeltaItem(
            providerId: 'space-a',
            path: '/Photos/Phone/IMG_0001.jpg',
            seq: 1,
            tombstone: false,
            capturedAt: 1000,
            size: 1, // contradicts the 4096 bytes actually sent
          ),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));
      expect(await mirror.itemsNeedingUploadRetry(), hasLength(1));

      final engine = GallerySyncEngine(mirror, uploadService);
      final result = await engine.run();

      expect(result.outcome, GallerySyncOutcome.completed);
      expect(result.uploaded, 1);
      expect(backend.removeCalls, [('space-a', '/Photos/Phone/IMG_0001.jpg')],
          reason: 'the untrusted remote file is deleted before the retry '
              'PUT, exactly as a direct retryMismatchedUpload call would');
      expect(backend.putCalls, hasLength(2),
          reason: 'the original upload plus the engine-driven retry');
      expect(await mirror.itemsNeedingUploadRetry(), isEmpty);
    });

    test('a per-item failure is counted and does not stop the run', () async {
      await scanDevicePhoto(
        displayName: 'IMG_0001.jpg',
        capturedAtSeconds: 1000,
        bytes: _bytesOfLength(1000),
      );
      await scanDevicePhoto(
        displayName: 'IMG_0002.jpg',
        capturedAtSeconds: 2000,
        bytes: _bytesOfLength(2000),
      );
      backend.statError =
          const GalleryUploadException('Seraph is out of storage space.');

      final engine = GallerySyncEngine(mirror, uploadService, concurrency: 1);
      final result = await engine.run();

      expect(result.outcome, GallerySyncOutcome.completed);
      expect(result.uploaded, 0);
      expect(result.failed, 2);

      final state = await mirror.syncRunState();
      expect(state.status, syncStatusCompleted);
      expect(state.failedItems, 2);
      expect(state.lastError, isNotNull);
    });

    test('requestPause takes effect promptly: no new item starts once '
        'called, and a later run() picks up exactly where it left off',
        () async {
      await scanDevicePhoto(
        displayName: 'IMG_0001.jpg',
        capturedAtSeconds: 3000,
        bytes: _bytesOfLength(1000),
      );
      await scanDevicePhoto(
        displayName: 'IMG_0002.jpg',
        capturedAtSeconds: 2000,
        bytes: _bytesOfLength(1000),
      );
      await scanDevicePhoto(
        displayName: 'IMG_0003.jpg',
        capturedAtSeconds: 1000,
        bytes: _bytesOfLength(1000),
      );

      // concurrency: 1 makes this deterministic - pause fires between two
      // sequential items rather than racing a pool of them. The fake
      // backend's onPut hook fires synchronously, right after the first
      // PUT is recorded but before anything else in that item's upload -
      // requestPause() runs from inside it, so "pausing takes effect
      // promptly" is exercised exactly, with no reliance on real timing a
      // zero-delay fake has none of.
      final engine = GallerySyncEngine(mirror, uploadService, concurrency: 1);
      backend.onPut = () {
        if (backend.putCalls.length == 1) {
          engine.requestPause();
        }
      };
      final result = await engine.run();

      expect(result.outcome, GallerySyncOutcome.paused);
      expect(backend.putCalls, hasLength(1),
          reason: 'pausing must stop new items being picked up before the '
              'whole queue drains - only the item already in flight when '
              'requestPause() was called completes');
      final pausedState = await mirror.syncRunState();
      expect(pausedState.status, syncStatusPaused);
      expect(pausedState.lastSuccessAt, isNull,
          reason: 'ticket 24: a paused run has not completed, so there is '
              'no successful pass to record yet');

      final resumed = await engine.run();
      expect(resumed.outcome, GallerySyncOutcome.completed);
      expect(backend.putCalls, hasLength(3),
          reason: 'resuming (a second run()) finishes whatever the paused '
              'run left behind - itemsPendingUpload never re-offers an '
              'already-uploaded item');
      final finalState = await mirror.syncRunState();
      expect(finalState.status, syncStatusCompleted);
      expect(finalState.completedItems, finalState.totalItems);
      expect(finalState.lastSuccessAt, isNotNull,
          reason: 'ticket 24: the run that actually finished must record '
              'when it did');
    });

    // Ticket 24's own criterion: "the time of the last successful pass is
    // visible in the app, so silence is distinguishable from success" -
    // covered at the mirror seam directly against
    // [GalleryMirror.writeSyncRunState], the single place [lastSuccessAt] is
    // computed, rather than only indirectly through the engine.
    test('SyncRunState.lastSuccessAt is set only when a run completes, and '
        'never regresses on a later write that does not', () async {
      var now = DateTime.fromMillisecondsSinceEpoch(1000000);
      final engine = GallerySyncEngine(mirror, uploadService, now: () => now);

      // An empty queue still writes syncStatusCompleted (see
      // GallerySyncEngine.run's own "nothingToDo" doc) - lastSuccessAt must
      // be set even though nothing was uploaded, since "successful pass"
      // means the run finished, not that it moved bytes.
      await engine.run();
      final afterFirst = await mirror.syncRunState();
      expect(afterFirst.status, syncStatusCompleted);
      expect(afterFirst.lastSuccessAt, now.millisecondsSinceEpoch);

      // A later write that does NOT complete (paused, or - as here, driven
      // directly to also cover the error case a real run's failed session
      // load produces) must carry the earlier timestamp forward untouched,
      // not clear it or move it.
      now = now.add(const Duration(hours: 1));
      await mirror.writeSyncRunState(
        status: syncStatusError,
        totalItems: 0,
        completedItems: 0,
        failedItems: 0,
        totalBytes: 0,
        completedBytes: 0,
        lastError: 'Not signed in',
        updatedAtMillis: now.millisecondsSinceEpoch,
      );
      final afterError = await mirror.syncRunState();
      expect(afterError.status, syncStatusError);
      expect(afterError.lastSuccessAt, afterFirst.lastSuccessAt,
          reason: 'a run that never even started must not erase the record '
              'of the last time one actually finished - that is exactly '
              'what makes silence distinguishable from success');

      // A later write that DOES complete moves it forward again.
      now = now.add(const Duration(hours: 1));
      await mirror.writeSyncRunState(
        status: syncStatusCompleted,
        totalItems: 1,
        completedItems: 1,
        failedItems: 0,
        totalBytes: 10,
        completedBytes: 10,
        updatedAtMillis: now.millisecondsSinceEpoch,
      );
      final afterSecondSuccess = await mirror.syncRunState();
      expect(afterSecondSuccess.lastSuccessAt, now.millisecondsSinceEpoch);
      expect(afterSecondSuccess.lastSuccessAt,
          greaterThan(afterFirst.lastSuccessAt!));
    });

    // Ticket 25's queue policy: two priority classes, newest first within
    // each.
    group('queue policy - priority classes', () {
      test(
          'a photo observed after the last completed pass preempts the '
          'remaining historical backlog, newest first within each class - '
          'even when the backlog\'s own Capture Date is NEWER than the '
          'fresh photos\'', () async {
        var clockMillis = 1000000;

        // The historical backlog - X and Y - lives under a folder no Sync
        // Pair covers YET, so the first run below never sees them at all
        // (itemsPendingUpload requires ACTIVE coverage); only their
        // observed-at timestamp (T0) is what matters later, not whether
        // anything tried to upload them yet.
        await scanDevicePhoto(
          relativePath: 'DCIM/Backlog/',
          displayName: 'X.jpg',
          capturedAtSeconds: 100,
          bytes: _bytesOfLength(100),
          nowMillis: clockMillis,
        );
        await scanDevicePhoto(
          relativePath: 'DCIM/Backlog/',
          displayName: 'Y.jpg',
          capturedAtSeconds: 200,
          bytes: _bytesOfLength(100),
          nowMillis: clockMillis,
        );
        // A filler photo under the folder already covered by setUp's Sync
        // Pair, so this run has something to actually complete - what
        // establishes SyncRunState.lastSuccessAt as the baseline the next
        // run's priority split is measured against.
        await scanDevicePhoto(
          displayName: 'filler.jpg',
          capturedAtSeconds: 1,
          bytes: _bytesOfLength(50),
          nowMillis: clockMillis,
        );

        final engine = GallerySyncEngine(mirror, uploadService,
            concurrency: 1,
            now: () => DateTime.fromMillisecondsSinceEpoch(clockMillis));
        final firstRun = await engine.run();
        expect(firstRun.outcome, GallerySyncOutcome.completed);
        expect(firstRun.uploaded, 1,
            reason: 'X and Y are not covered by any Sync Pair yet');
        final afterFirst = await mirror.syncRunState();
        expect(afterFirst.lastSuccessAt, clockMillis);

        // Time passes. A Sync Pair now covers DCIM/Backlog/ - X and Y
        // become upload candidates for the first time, but their
        // observed-at timestamp is still T0, at/before the baseline just
        // recorded. Two genuinely fresh photos, P and Q, are observed now -
        // deliberately given an OLDER Capture Date than X/Y, so an ordering
        // driven by Capture Date alone would rank them BEHIND the backlog;
        // the priority split must not do that.
        clockMillis += 60000;
        await mirror.createSyncPair(
          localFolderPath: 'DCIM/Backlog/',
          spaceProviderId: 'space-a',
          path: '/Photos/Backlog',
        );
        await scanDevicePhoto(
          displayName: 'P.jpg',
          capturedAtSeconds: 10,
          bytes: _bytesOfLength(100),
          nowMillis: clockMillis,
        );
        await scanDevicePhoto(
          displayName: 'Q.jpg',
          capturedAtSeconds: 20,
          bytes: _bytesOfLength(100),
          nowMillis: clockMillis,
        );

        final secondRun = await engine.run();
        expect(secondRun.outcome, GallerySyncOutcome.completed);
        expect(secondRun.uploaded, 4);
        expect(
          backend.putCalls.skip(1).map((c) => c.$2).toList(),
          [
            '/Photos/Phone/Q.jpg',
            '/Photos/Phone/P.jpg',
            '/Photos/Backlog/Y.jpg',
            '/Photos/Backlog/X.jpg',
          ],
          reason: 'fresh (Q, P - newest first) entirely ahead of backlog '
              '(Y, X - newest first), regardless of Capture Date',
        );
      });
    });

    // Ticket 25's queue policy: the three failure buckets.
    group('queue policy - failure buckets', () {
      test(
          'transient failures retry with increasing per-item delays, and '
          'are excluded from the queue until each window passes', () async {
        var clockMillis = 1000000;
        final photo = await scanDevicePhoto(
          displayName: 'IMG_0001.jpg',
          capturedAtSeconds: 1000,
          bytes: _bytesOfLength(500),
        );
        backend.putError = const GalleryUploadException('connection lost');

        final engine = GallerySyncEngine(mirror, uploadService,
            now: () => DateTime.fromMillisecondsSinceEpoch(clockMillis));

        final first = await engine.run();
        expect(first.outcome, GallerySyncOutcome.completed);
        expect(first.failed, 1);
        var row = (await mirror.queryItems())
            .firstWhere((i) => i.id == photo.id);
        expect(row.uploadAttempts, 1);
        expect(row.uploadNextRetryAt, clockMillis + 30000,
            reason: 'the default per-item base delay');

        // Still inside the first backoff window - must not be re-offered.
        clockMillis += 10000;
        final second = await engine.run();
        expect(second.outcome, GallerySyncOutcome.nothingToDo);
        expect(backend.putCalls, hasLength(1),
            reason: 'no NEW attempt while still inside the backoff window '
                '- the one entry is the first (failed) attempt itself');

        // Past the window - retried, fails again, the delay doubles.
        clockMillis += 25000;
        final third = await engine.run();
        expect(third.outcome, GallerySyncOutcome.completed);
        expect(third.failed, 1);
        expect(backend.putCalls, hasLength(2));
        row =
            (await mirror.queryItems()).firstWhere((i) => i.id == photo.id);
        expect(row.uploadAttempts, 2);
        expect(row.uploadNextRetryAt, clockMillis + 60000,
            reason: '30s * 2^1 - the schedule doubles on the second '
                'consecutive failure');
      });

      test(
          'a server that is down trips a global backoff instead of '
          'retrying every remaining item individually, and no network call '
          'happens at all while the cooldown is in effect', () async {
        var clockMillis = 1000000;
        for (var i = 0; i < 5; i++) {
          await scanDevicePhoto(
            displayName: 'IMG_000$i.jpg',
            capturedAtSeconds: 1000 + i,
            bytes: _bytesOfLength(100),
          );
        }
        // A permanently failing backend - never clears, exactly the
        // ticket's own "global-backoff test with a permanently failing
        // backend" coverage requirement.
        backend.putError = const GalleryUploadException('connection lost');

        final engine = GallerySyncEngine(mirror, uploadService,
            concurrency: 1,
            globalBackoffThreshold: 3,
            globalBackoffBaseDelay: const Duration(minutes: 1),
            now: () => DateTime.fromMillisecondsSinceEpoch(clockMillis));

        final result = await engine.run();
        expect(result.outcome, GallerySyncOutcome.globalBackoff);
        expect(backend.putCalls, hasLength(3),
            reason: 'the breaker trips after 3 consecutive transient '
                'failures - the other 2 queued items are abandoned for '
                'this run rather than each independently retried');
        final state = await mirror.syncRunState();
        expect(state.status, syncStatusBackoff);
        expect(state.globalBackoffStreak, 1);
        expect(state.globalBackoffUntil, clockMillis + 60000);

        // Inside the cooldown window - not one more network call is made.
        clockMillis += 1000;
        final duringBackoff = await engine.run();
        expect(duringBackoff.outcome, GallerySyncOutcome.globalBackoff);
        expect(backend.putCalls, hasLength(3));

        // Past the window, still down: the breaker trips again and the
        // schedule grows.
        clockMillis += 60000;
        final secondTrip = await engine.run();
        expect(secondTrip.outcome, GallerySyncOutcome.globalBackoff);
        final state2 = await mirror.syncRunState();
        expect(state2.globalBackoffStreak, 2);
        expect(state2.globalBackoffUntil, clockMillis + 120000,
            reason: '60s * 2^1 - doubled on the second consecutive trip');
      });

      test(
          'a permanent failure stops retrying and appears in the visible '
          'failure list with a reason; retrying it needs no '
          'reconfiguration', () async {
        final photo = await scanDevicePhoto(
          displayName: 'IMG_0001.jpg',
          capturedAtSeconds: 1000,
          bytes: _bytesOfLength(500),
        );
        backend.statError = const GalleryUploadException(
          'This Space is read-only - uploading is not allowed here.',
          readOnly: true,
          bucket: GalleryUploadFailureBucket.permanent,
        );

        final engine = GallerySyncEngine(mirror, uploadService);
        final result = await engine.run();
        expect(result.outcome, GallerySyncOutcome.completed);
        expect(result.failed, 1);

        expect(await mirror.itemsPendingUpload(), isEmpty,
            reason: 'a permanent failure must never be silently retried');
        final failures = await mirror.failedUploadItems();
        expect(failures, hasLength(1));
        expect(failures.single.id, photo.id);
        expect(failures.single.uploadFailureReason, contains('read-only'));

        // The retry action - clears the failure with no Sync Pair or
        // setting touched, so the very next run picks it up normally.
        backend.statError = null;
        await mirror.retryFailedUpload(photo.id);
        expect(await mirror.failedUploadItems(), isEmpty);

        final second = await engine.run();
        expect(second.outcome, GallerySyncOutcome.completed);
        expect(second.uploaded, 1);
        expect(backend.putCalls, hasLength(1));
      });

      test(
          'a device copy this engine cannot read (permission revoked, or '
          'the file genuinely gone) is a PERMANENT failure - parked in the '
          'visible failure list, never silently counted as completed - and '
          'retrying it re-attempts for real once the file is readable '
          'again', () async {
        final photo = await scanDevicePhoto(
          displayName: 'IMG_0001.jpg',
          capturedAtSeconds: 1000,
          bytes: _bytesOfLength(500),
        );
        localSource.forgetLocalBytes('DCIM/Camera/', 'IMG_0001.jpg');

        final engine = GallerySyncEngine(mirror, uploadService);
        final first = await engine.run();
        expect(first.outcome, GallerySyncOutcome.completed);
        expect(first.uploaded, 0,
            reason: 'an unreadable local file must NOT be counted as '
                'completed - that is exactly the silent-success defect '
                'this bucket exists to close');
        expect(first.failed, 1);
        expect(backend.putCalls, isEmpty,
            reason: 'never even reaches the network - caught on the local '
                'read, same as before');

        final failures = await mirror.failedUploadItems();
        expect(failures, hasLength(1));
        expect(failures.single.id, photo.id);
        expect(failures.single.uploadFailureReason, isNotNull);

        // Excluded from the ordinary queue, exactly like any other
        // PERMANENT failure - never silently retried forever.
        expect(await mirror.itemsPendingUpload(), isEmpty);
        final row =
            (await mirror.queryItems()).firstWhere((i) => i.id == photo.id);
        expect(row.availability, GalleryAvailability.deviceOnly);

        // The user regains photo access; the file is readable again. The
        // existing Retry action (GalleryMirror.retryFailedUpload) clears
        // the bucket, and the very next run genuinely re-attempts rather
        // than immediately re-parking it.
        localSource.setLocalBytes(
            'DCIM/Camera/', 'IMG_0001.jpg', _bytesOfLength(500));
        await mirror.retryFailedUpload(photo.id);
        expect(await mirror.failedUploadItems(), isEmpty);

        final second = await engine.run();
        expect(second.outcome, GallerySyncOutcome.completed);
        expect(second.uploaded, 1);
        expect(second.failed, 0);
        expect(backend.putCalls, hasLength(1));
        expect(await mirror.failedUploadItems(), isEmpty);
      });

      test(
          'a device file that merely changed size mid-upload (a racing '
          'scan, a same-second edit) is left untouched and simply offered '
          'again next run - never marked synced, never added to the '
          'failure list, unlike an unreadable file', () async {
        final photo = await scanDevicePhoto(
          displayName: 'IMG_0001.jpg',
          capturedAtSeconds: 1000,
          bytes: _bytesOfLength(500),
        );
        // The device copy read back a different length than the mirror row
        // recorded at scan time - GalleryUploadResult.deviceFileChanged,
        // the OTHER never-throws outcome, deliberately left alone.
        localSource.setLocalBytes(
            'DCIM/Camera/', 'IMG_0001.jpg', _bytesOfLength(999));

        final engine = GallerySyncEngine(mirror, uploadService);
        final first = await engine.run();
        expect(first.outcome, GallerySyncOutcome.completed);
        expect(first.uploaded, 1,
            reason: 'attempted, not failed - this is not this engine\'s '
                'job to police (ticket 22)');
        expect(first.failed, 0);
        expect(backend.putCalls, isEmpty);
        expect(await mirror.failedUploadItems(), isEmpty);
        final rowAfterFirst =
            (await mirror.queryItems()).firstWhere((i) => i.id == photo.id);
        expect(rowAfterFirst.availability, GalleryAvailability.deviceOnly);

        // The race resolves itself - the device copy is back to the size
        // the mirror row expects. No special recovery action needed - the
        // very next run offers it again on its own, this time matching.
        localSource.setLocalBytes(
            'DCIM/Camera/', 'IMG_0001.jpg', _bytesOfLength(500));
        final second = await engine.run();
        expect(second.outcome, GallerySyncOutcome.completed);
        expect(second.uploaded, 1);
        expect(backend.putCalls, hasLength(1));
      });

      test(
          'losing the queue bookkeeping entirely costs only a rebuild - '
          'nothing already Verified is re-uploaded, and a parked failure '
          'simply becomes pending again', () async {
        // One item that reaches Verified through the normal upload + feed
        // path - this must NEVER be re-uploaded, queue loss or not.
        final verified = await scanDevicePhoto(
          displayName: 'verified.jpg',
          capturedAtSeconds: 1000,
          bytes: _bytesOfLength(1000),
        );
        await uploadService.upload(verified);
        await mirror.applyPage(GalleryDeltaResponse(
          items: [
            GalleryDeltaItem(
              providerId: 'space-a',
              path: '/Photos/Phone/verified.jpg',
              seq: 1,
              tombstone: false,
              capturedAt: 1000,
              size: 1000,
            ),
          ],
          nextCursor: '',
          hasMore: false,
          nextSince: 1,
        ));
        final verifiedRow = (await mirror.queryItems())
            .firstWhere((i) => i.id == verified.id);
        expect(verifiedRow.availability, GalleryAvailability.synced);

        // A second item whose upload permanently failed - parked in the
        // failure list, this ticket's own machinery.
        final failed = await scanDevicePhoto(
          displayName: 'failed.jpg',
          capturedAtSeconds: 2000,
          bytes: _bytesOfLength(500),
        );
        backend.statError = const GalleryUploadException(
          'Seraph is out of storage space.',
          bucket: GalleryUploadFailureBucket.permanent,
        );
        final engine = GallerySyncEngine(mirror, uploadService);
        await engine.run();
        expect(await mirror.failedUploadItems(), hasLength(1));
        backend.statError = null;

        // Simulate the queue itself being lost or corrupted - directly
        // blanking the bookkeeping columns, NOT going through
        // GalleryMirror.retryFailedUpload (a user action): the point is
        // that losing this derived state by accident costs nothing beyond
        // a rebuild, per the spec's own "the queue is derived state, not
        // durable truth" rule.
        await (db.update(db.galleryItems)
              ..where((t) => t.id.equals(failed.id)))
            .write(const GalleryItemsCompanion(
          uploadFailureBucket: Value(null),
          uploadFailureReason: Value(null),
          uploadAttempts: Value(0),
          uploadNextRetryAt: Value(null),
        ));

        final putCallsBeforeRebuild = backend.putCalls.length;
        final rebuilt = await engine.run();
        expect(rebuilt.outcome, GallerySyncOutcome.completed);
        expect(rebuilt.uploaded, 1);
        expect(
          backend.putCalls.skip(putCallsBeforeRebuild).map((c) => c.$2),
          ['/Photos/Phone/failed.jpg'],
          reason: 'exactly one NEW put - the rebuilt item - and nothing '
              'else; a Verified item is never even offered to the queue '
              'again, scan-rebuilt or not',
        );
      });

      test(
          'a row parked awaiting a mismatch retry is no longer selected by '
          'itemsNeedingUploadRetry once its Sync Pair is removed - a '
          'removed pair must not leave the row retried (and silently '
          'counted as sent) forever', () async {
        final uploaded = await scanDevicePhoto(
          displayName: 'IMG_0001.jpg',
          capturedAtSeconds: 1000,
          bytes: _bytesOfLength(4096),
        );
        await uploadService.upload(uploaded);
        await mirror.applyPage(GalleryDeltaResponse(
          items: [
            GalleryDeltaItem(
              providerId: 'space-a',
              path: '/Photos/Phone/IMG_0001.jpg',
              seq: 1,
              tombstone: false,
              capturedAt: 1000,
              size: 1, // contradicts the 4096 bytes actually sent
            ),
          ],
          nextCursor: '',
          hasMore: false,
          nextSince: 1,
        ));
        expect(await mirror.itemsNeedingUploadRetry(), hasLength(1),
            reason: 'covered by an active Sync Pair - a normal retry '
                'candidate');

        final pair = (await mirror.listSyncPairs()).single;
        await mirror.removeSyncPair(pair.id);

        expect(await mirror.itemsNeedingUploadRetry(), isEmpty,
            reason: 'ticket 21\'s rule is "current target for WRITES" - a '
                'retry is a write, so it must use active coverage, the '
                'same as itemsPendingUpload, not the all-historical-targets '
                'rule lookups use');

        // A run finds nothing to do - the row is neither retried nor
        // counted, indefinitely, exactly what removing a Sync Pair should
        // do to it (ticket 21: nothing about existing photos changes).
        final engine = GallerySyncEngine(mirror, uploadService);
        final result = await engine.run();
        expect(result.outcome, GallerySyncOutcome.nothingToDo);
      });

      test(
          'a Sync Pair removed in the window between a run building its '
          'queue and reaching a row - a live race the query-level fix '
          'alone cannot close - still does not let noSyncPair (or '
          'notApplicable) inflate the completed count', () async {
        final pair = (await mirror.listSyncPairs()).single;

        Future<GalleryItem> mismatchedItem(String displayName, int seq) async {
          final uploaded = await scanDevicePhoto(
            displayName: displayName,
            capturedAtSeconds: seq,
            bytes: _bytesOfLength(4096),
          );
          await uploadService.upload(uploaded);
          await mirror.applyPage(GalleryDeltaResponse(
            items: [
              GalleryDeltaItem(
                providerId: 'space-a',
                path: '/Photos/Phone/$displayName',
                seq: seq,
                tombstone: false,
                capturedAt: seq,
                size: 1, // contradicts what was actually sent
              ),
            ],
            nextCursor: '',
            hasMore: false,
            nextSince: seq,
          ));
          return uploaded;
        }

        // Two rows queued for retry while the pair is still active - the
        // queue this run() call builds legitimately contains both.
        await mismatchedItem('a.jpg', 1);
        await mismatchedItem('b.jpg', 2);
        expect(await mirror.itemsNeedingUploadRetry(), hasLength(2));

        // The pair is removed mid-run, right after the FIRST item's PUT
        // lands (and is guaranteed complete by then - onPutAsync is
        // awaited, unlike a plain synchronous hook) - simulating the
        // window between this run's queue snapshot and it reaching the
        // second item, which the query-level fix alone cannot close.
        var removed = false;
        backend.onPutAsync = () async {
          if (!removed) {
            removed = true;
            await mirror.removeSyncPair(pair.id);
          }
        };

        final engine =
            GallerySyncEngine(mirror, uploadService, concurrency: 1);
        final result = await engine.run();

        // The first row: a genuine, already-in-flight retry - completes
        // normally. The second: expectedUploadTarget now finds no active
        // pair and returns GalleryUploadResult.noSyncPair - a skip, not a
        // success and not a failure.
        expect(result.uploaded, 1,
            reason: 'only the row actually retried counts as completed - '
                'noSyncPair must not inflate this');
        expect(result.failed, 0,
            reason: 'a removed Sync Pair is the user\'s own configuration '
                'choice (ticket 21), not a backup failure');
        expect(await mirror.failedUploadItems(), isEmpty,
            reason: 'must never appear in the visible failure list either');

        final state = await mirror.syncRunState();
        expect(state.totalItems, 2);
        expect(state.completedItems, 1);
        expect(state.failedItems, 0);
      });
    });
  });
}
