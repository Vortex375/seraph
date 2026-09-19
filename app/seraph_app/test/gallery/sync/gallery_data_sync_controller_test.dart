import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Value;
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/sync/gallery_data_sync_controller.dart';
import 'package:seraph_app/src/gallery/sync/gallery_data_sync_types.dart';

import '../gallery_test_support.dart';

/// A [GalleryDataSyncService] that records calls instead of driving a real
/// foreground service - so [GalleryDataSyncController.startBackup] can be
/// asserted on without standing up the headless isolate.
class _FakeGalleryDataSyncService implements GalleryDataSyncService {
  int startCalls = 0;

  @override
  Future<void> start() async {
    startCalls++;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<bool> isRunning() async => false;
}

/// [GalleryDataSyncController.startBackup] is what the Gallery folders
/// screen's backup button is wired to. The button must retry previously
/// failed (permanently-parked) uploads, not only files never backed up
/// before - without this, permanently-failed rows stay excluded from the
/// engine's queue and pressing "backup" does nothing for them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Get.testMode = true;

  late GalleryMirrorDatabase db;
  late GalleryMirror mirror;
  late _FakeGalleryDataSyncService service;

  setUp(() async {
    Get.reset();
    db = GalleryMirrorDatabase(NativeDatabase.memory());
    mirror = GalleryMirror(db);
    service = _FakeGalleryDataSyncService();

    await mirror.createSyncPair(
      localFolderPath: 'DCIM/Camera/',
      spaceProviderId: 'space-a',
      path: '/Photos/Phone',
    );
  });

  tearDown(() async {
    Get.reset();
    await db.close();
  });

  Future<void> seedFailedPhotos(int count) async {
    await mirror.applyLocalScan([
      for (var i = 0; i < count; i++)
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'IMG_${i.toString().padLeft(4, '0')}.jpg',
          size: 1,
        ),
    ]);
    // Park every scanned row as permanently failed, the same end state a run
    // against a permanently-failing backend would leave - without the
    // engine/backend setup this controller test does not need.
    await (db.update(db.galleryItems)
          ..where((t) => t.uploadFailureBucket.isNull()))
        .write(const GalleryItemsCompanion(
      uploadFailureBucket: Value('permanent'),
      uploadFailureReason: Value('No space left on Seraph.'),
    ));
  }

  test(
      'startBackup clears every permanently-failed upload before starting the '
      'run, so the engine re-attempts all of them rather than skipping them',
      () async {
    await seedFailedPhotos(3);
    final controller = GalleryDataSyncController(
      mirror,
      service: service,
      pollInterval: const Duration(minutes: 60),
    );
    // Prime the failure list the way the controller's own startup poll
    // would, so the pre-call state is visibly non-empty.
    controller.failedItems.value = await mirror.failedUploadItems();
    expect(controller.failedItems, hasLength(3));
    expect(service.startCalls, 0);

    await controller.startBackup();

    expect(service.startCalls, 1,
        reason: 'the backup button still starts the run after clearing');
    expect(await mirror.failedUploadItems(), isEmpty,
        reason: 'every permanently-failed row is cleared, not just one');
    expect(await mirror.itemsPendingUpload(), hasLength(3),
        reason: 'each cleared row is an ordinary pending candidate again, '
            'so the next engine run re-attempts all of them');
    expect(controller.failedItems, isEmpty,
        reason: 'the controller refreshes its failure list from the mirror '
            'so the UI drops the failure section immediately');
  });

  test(
      'startBackup with no failed uploads still starts the run, and changes '
      'nothing about the queue', () async {
    // No photos at all - nothing failed, nothing pending.
    final controller = GalleryDataSyncController(
      mirror,
      service: service,
      pollInterval: const Duration(minutes: 60),
    );
    expect(service.startCalls, 0);

    await controller.startBackup();

    expect(service.startCalls, 1);
    expect(await mirror.failedUploadItems(), isEmpty);
    expect(await mirror.itemsPendingUpload(), isEmpty);
  });

  test(
      'retryFailedItem clears only its one item and then starts - the per-item '
      'Retry button does not bulk-clear the rest of the failure list',
      () async {
    await seedFailedPhotos(3);
    final controller = GalleryDataSyncController(
      mirror,
      service: service,
      pollInterval: const Duration(minutes: 60),
    );
    controller.failedItems.value = await mirror.failedUploadItems();
    final target = controller.failedItems.first;

    await controller.retryFailedItem(target);

    expect(service.startCalls, 1);
    expect(await mirror.failedUploadItems(), hasLength(2),
        reason: 'only the retried item is cleared; the other two permanently '
            'failed rows remain parked, untouched by the per-item action');
  });
}
