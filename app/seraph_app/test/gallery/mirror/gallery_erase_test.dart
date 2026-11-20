import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/local/local_scan_service.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_delta_models.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_erase_service.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_upload_backend.dart';

import '../gallery_test_support.dart';

/// Ticket 27 at the mirror seam: fake Local Source, fake backend, real
/// mirror. The cancelled-dialog and restored-from-trash cases each run a
/// full scan afterwards and assert nothing is queued for upload.
void main() {
  late GalleryMirrorDatabase db;
  late GalleryMirror mirror;
  late FakeLocalSource source;
  late FakeGalleryUploadBackend backend;
  late LocalScanService scan;
  late GalleryEraseService erase;

  final photo = localMediaItem(
      relativePath: 'DCIM/Camera/',
      displayName: 'a.jpg',
      size: 4096,
      dateTakenMillis: 1700000000000);

  setUp(() async {
    db = GalleryMirrorDatabase(NativeDatabase.memory());
    mirror = GalleryMirror(db);
    source = FakeLocalSource([photo]);
    backend = FakeGalleryUploadBackend();
    scan = LocalScanService(mirror, localSource: source);
    erase = GalleryEraseService(mirror, backend, scan);
    await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'p',
        path: '/Photos/Phone');
    // Seraph holds the photo at the Sync Pair's path -> Synced after a scan.
    await mirror.applyPage(GalleryDeltaResponse(
      items: [
        GalleryDeltaItem(
            providerId: 'p',
            path: '/Photos/Phone/a.jpg',
            seq: 1,
            tombstone: false,
            capturedAt: 1700000000,
            size: 4096),
      ],
      nextCursor: '',
      hasMore: false,
      nextSince: 1,
    ));
    await scan.scan();
  });

  tearDown(() async => db.close());

  Future<int> theId() async =>
      (await db.select(db.galleryItems).get()).single.id;

  Future<void> expectNothingQueued() async =>
      expect(await mirror.itemsPendingUpload(), isEmpty);

  test('erase deletes the Seraph copy first, then trashes the device copy',
      () async {
    final result = await erase.erase([await theId()]);

    expect(result.erased, 1);
    expect(result.cancelled, isFalse);
    expect(backend.removeCalls, [('p', '/Photos/Phone/a.jpg')]);
    expect(source.trashCalls.single.single.displayName, 'a.jpg');
    expect(await db.select(db.galleryItems).get(), isEmpty);
    await scan.scan();
    await expectNothingQueued();
  });

  test('cancelling the device dialog keeps the photo and never re-uploads it',
      () async {
    source.confirmTrash = false;
    final result = await erase.erase([await theId()]);
    expect(result.cancelled, isTrue);
    expect(result.erased, 1);

    await scan.scan();
    await scan.scan();
    final row = (await db.select(db.galleryItems).get()).single;
    expect(row.origin, 'device');
    expect(row.erased, isTrue);
    await expectNothingQueued();
  });

  test('restoring from the trash leaves it Device only, not re-uploaded',
      () async {
    await erase.erase([await theId()]);
    source.setItems([photo]); // restored from the system trash
    await scan.scan();

    final row = (await db.select(db.galleryItems).get()).single;
    expect(row.origin, 'device');
    expect(row.erased, isTrue);
    await expectNothingQueued();
  });

  test('"back this up again" clears the tombstone and queues the upload',
      () async {
    source.confirmTrash = false;
    await erase.erase([await theId()]);
    await scan.scan();

    expect(await mirror.backUpAgain([await theId()]), 1);
    expect(await db.select(db.eraseTombstones).get(), isEmpty);
    expect((await mirror.itemsPendingUpload()).single.localDisplayName,
        'a.jpg');
  });

  test('tombstones survive an app restart', () async {
    source.confirmTrash = false;
    await erase.erase([await theId()]);

    // A fresh mirror over the same database stands in for a restart.
    final restarted = GalleryMirror(db);
    final restartedScan = LocalScanService(restarted, localSource: source);
    await restartedScan.scan();
    expect((await db.select(db.galleryItems).get()).single.erased, isTrue);
    expect(await restarted.itemsPendingUpload(), isEmpty);
  });

  test('a remote failure aborts before anything local is touched', () async {
    backend.removeError = const GalleryUploadException('offline');
    final result = await erase.erase([await theId()]);

    expect(result.erased, 0);
    expect(result.failure, 'offline');
    expect(source.trashCalls, isEmpty);
    expect(await db.select(db.eraseTombstones).get(), isEmpty);
    final row = (await db.select(db.galleryItems).get()).single;
    expect(row.origin, 'both');
    expect(row.erased, isFalse);
  });

  test('a batch is erased with a single system dialog', () async {
    final second = localMediaItem(
        relativePath: 'DCIM/Camera/',
        displayName: 'b.jpg',
        size: 1024,
        dateTakenMillis: 1700000500000);
    source.setItems([photo, second]);
    await scan.scan();

    final ids = [for (final r in await db.select(db.galleryItems).get()) r.id];
    final result = await erase.erase(ids);

    expect(result.erased, 2);
    expect(source.trashCalls.length, 1);
    expect(source.trashCalls.single.length, 2);
  });
}
