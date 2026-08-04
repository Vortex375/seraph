import 'dart:typed_data';

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
    }) async {
      scannedItems.add(localMediaItem(
        relativePath: relativePath,
        displayName: displayName,
        size: bytes.length,
        dateTakenMillis: capturedAtSeconds * 1000,
      ));
      await mirror.applyLocalScan(scannedItems);
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
  });
}
