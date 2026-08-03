import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_delta_models.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_upload_backend.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_upload_service.dart';

import '../gallery_test_support.dart';

Uint8List _bytesOfLength(int length, [int fill = 0x42]) =>
    Uint8List.fromList(List<int>.filled(length, fill));

/// Ticket 19's mirror-seam coverage: upload one Device only photo end to end
/// against [FakeGalleryUploadBackend] and a [FakeLocalSource] - exactly the
/// seam ticket 13 established and the ticket's own "covered at the app's
/// mirror seam with a stubbed backend, including collision, disambiguation
/// and interruption cases" criterion.
///
/// **Not covered here, deliberately:** recursive intermediate-folder
/// creation. [GalleryUploadBackend.put] is the seam - a real
/// [WebDavGalleryUploadBackend] delegates the actual PUT to
/// `webdav_client`'s own `Client.write`, which already retries a 409 with
/// `mkdirAll` before writing (see that class's doc). [FakeGalleryUploadBackend]
/// is a flat map with no folder structure to create, so it cannot exercise
/// that behaviour - re-testing a dependency's own, already-tested behaviour
/// through a fake that cannot represent it would only be a test that always
/// passes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GalleryUploadService.upload', () {
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;
    late FakeGalleryUploadBackend backend;
    late FakeLocalSource localSource;
    late GalleryUploadService service;

    setUp(() async {
      db = GalleryMirrorDatabase(NativeDatabase.memory());
      mirror = GalleryMirror(db);
      backend = FakeGalleryUploadBackend();
      localSource = FakeLocalSource();
      service = GalleryUploadService(mirror, backend, localSource);

      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
    });

    tearDown(() async {
      await db.close();
    });

    Future<GalleryItem> scanOneDevicePhoto({
      String relativePath = 'DCIM/Camera/2026/',
      String displayName = 'IMG_0001.jpg',
      required Uint8List bytes,
    }) async {
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: relativePath,
          displayName: displayName,
          size: bytes.length,
        ),
      ]);
      localSource.setLocalBytes(relativePath, displayName, bytes);
      return (await mirror.queryItems()).single;
    }

    test(
        'places the photo under the Sync Pair Seraph folder at its mirrored '
        'relative path, with no client-side staging, and the Seraph copy is '
        'byte-identical - but the item is not yet Synced (ticket 20: only '
        'the delta feed can make that true)', () async {
      final bytes = _bytesOfLength(4096);
      final item = await scanOneDevicePhoto(bytes: bytes);

      final result = await service.upload(item);

      expect(result, GalleryUploadResult.uploaded);
      expect(backend.putCalls, hasLength(1),
          reason: 'exactly one PUT - straight to the final path, no staging '
              'round trip');
      final call = backend.putCalls.single;
      expect(call.$1, 'space-a');
      expect(call.$2, '/Photos/Phone/2026/IMG_0001.jpg');
      expect(call.$3, bytes, reason: 'the Seraph copy must be byte-identical');

      final pending = (await mirror.queryItems()).single;
      expect(pending.availability, GalleryAvailability.deviceOnly,
          reason: 'ticket 20: the upload response alone must never mark an '
              'item Verified - it stays not-backed-up until the feed '
              'confirms it');
      expect(pending.isAwaitingVerification, isTrue,
          reason: 'shown as in progress, not as plain "on this device"');
      expect(pending.uploadTargetProviderId, 'space-a',
          reason: 'the path actually used is recorded against the item, '
              'for the feed-based verification to check against');
      expect(pending.uploadTargetPath, '/Photos/Phone/2026/IMG_0001.jpg');
    });

    test(
        'an occupied target path holding content of a different size is '
        'never overwritten - the upload goes to a disambiguated name',
        () async {
      final existing = _bytesOfLength(100, 0x11);
      backend.seed('space-a', '/Photos/Phone/2026/IMG_0001.jpg', existing);
      final bytes = _bytesOfLength(4096);
      final item = await scanOneDevicePhoto(bytes: bytes);

      final result = await service.upload(item);

      expect(result, GalleryUploadResult.uploaded);
      expect(
        backend.contentAt('space-a', '/Photos/Phone/2026/IMG_0001.jpg'),
        existing,
        reason: 'the occupied original path must be untouched',
      );
      final disambiguated =
          backend.contentAt('space-a', '/Photos/Phone/2026/IMG_0001 (1).jpg');
      expect(disambiguated, bytes,
          reason: 'the upload itself must have happened, under a new name');

      final pending = (await mirror.queryItems()).single;
      expect(pending.uploadTargetPath, '/Photos/Phone/2026/IMG_0001 (1).jpg',
          reason: 'the recorded path is the one actually used, not the '
              'originally computed one - what ticket 20 verification must '
              'check against');
    });

    test(
        'an occupied target path holding content of the same size results in '
        'no upload, and the item awaits verification the same as a real '
        'upload would', () async {
      final bytes = _bytesOfLength(4096, 0x11);
      // Different content, same length - the one case ticket 19 accepts
      // getting wrong.
      backend.seed('space-a', '/Photos/Phone/2026/IMG_0001.jpg',
          _bytesOfLength(4096, 0x99));
      final item = await scanOneDevicePhoto(bytes: bytes);

      final result = await service.upload(item);

      expect(result, GalleryUploadResult.alreadyPresent);
      expect(backend.putCalls, isEmpty, reason: 'no upload should happen');

      final pending = (await mirror.queryItems()).single;
      expect(pending.availability, GalleryAvailability.deviceOnly,
          reason: 'ticket 20: even the "assume it is ours" shortcut is not '
              'Seraph independently reporting the file - the feed still has '
              'to confirm it before this shows as backed up');
      expect(pending.isAwaitingVerification, isTrue);
      expect(pending.uploadTargetPath, '/Photos/Phone/2026/IMG_0001.jpg');
    });

    test(
        'an upload interrupted by a lost connection leaves no partial file '
        'and can be retried cleanly', () async {
      final bytes = _bytesOfLength(2048);
      final item = await scanOneDevicePhoto(bytes: bytes);
      backend.putError = const GalleryUploadException('connection lost');

      await expectLater(
        service.upload(item),
        throwsA(isA<GalleryUploadException>()),
      );
      expect(
        backend.contentAt('space-a', '/Photos/Phone/2026/IMG_0001.jpg'),
        isNull,
        reason: 'a failed PUT must leave nothing at the target path',
      );
      final stillDeviceOnly = (await mirror.queryItems()).single;
      expect(stillDeviceOnly.availability, GalleryAvailability.deviceOnly,
          reason: 'a failed upload must not be marked synced');

      // Retry, connection restored.
      backend.putError = null;
      final result = await service.upload(item);
      expect(result, GalleryUploadResult.uploaded);
      final pending = (await mirror.queryItems()).single;
      expect(pending.isAwaitingVerification, isTrue,
          reason: 'a successful retry still awaits feed verification, same '
              'as a first-attempt upload does');
    });

    test('a photo deleted from the device mid-upload is not marked synced',
        () async {
      final bytes = _bytesOfLength(2048);
      final item = await scanOneDevicePhoto(bytes: bytes);
      localSource.forgetLocalBytes('DCIM/Camera/2026/', 'IMG_0001.jpg');

      final result = await service.upload(item);

      expect(result, GalleryUploadResult.deviceFileUnavailable);
      expect(backend.putCalls, isEmpty,
          reason: 'nothing should be uploaded once the device copy is gone');
      expect(backend.statCalls, isEmpty,
          reason: 'not even the network should be touched');
      final stillDeviceOnly = (await mirror.queryItems()).single;
      expect(stillDeviceOnly.availability, GalleryAvailability.deviceOnly);
    });

    test(
        'a photo modified on the device (different length) mid-upload is not '
        'marked synced', () async {
      final item = await scanOneDevicePhoto(bytes: _bytesOfLength(2048));
      // The file on disk changed size after the scan that produced [item].
      localSource.setLocalBytes(
          'DCIM/Camera/2026/', 'IMG_0001.jpg', _bytesOfLength(9000));

      final result = await service.upload(item);

      expect(result, GalleryUploadResult.deviceFileChanged);
      expect(backend.putCalls, isEmpty);
      final stillDeviceOnly = (await mirror.queryItems()).single;
      expect(stillDeviceOnly.availability, GalleryAvailability.deviceOnly);
    });

    test(
        'uploading to a read-only Space fails with a comprehensible reason '
        'rather than silently, and the item is not marked synced', () async {
      final item = await scanOneDevicePhoto(bytes: _bytesOfLength(1024));
      backend.statError = const GalleryUploadException(
        'This Space is read-only.',
        readOnly: true,
      );

      await expectLater(
        service.upload(item),
        throwsA(isA<GalleryUploadException>()
            .having((e) => e.readOnly, 'readOnly', isTrue)
            .having((e) => e.message, 'message', isNotEmpty)),
      );
      final stillDeviceOnly = (await mirror.queryItems()).single;
      expect(stillDeviceOnly.availability, GalleryAvailability.deviceOnly);
    });

    test('a device folder with no Sync Pair reports noSyncPair and uploads '
        'nothing', () async {
      // Under DCIM (so ticket 29's default folder selection does not itself
      // hide the row from queryItems), but not under the Sync Pair's own
      // 'DCIM/Camera/' folder - covered by neither.
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Screenshots/',
          displayName: 'shot.png',
          size: 10,
        ),
      ]);
      localSource.setLocalBytes(
          'DCIM/Screenshots/', 'shot.png', _bytesOfLength(10));
      final item = (await mirror.queryItems())
          .firstWhere((i) => i.localDisplayName == 'shot.png');

      final result = await service.upload(item);

      expect(result, GalleryUploadResult.noSyncPair);
      expect(backend.statCalls, isEmpty);
      expect(backend.putCalls, isEmpty);
    });

    test('a device copy that cannot be read at all is not marked synced',
        () async {
      // Scanned, but the fake never got bytes for it - the "corrupt/
      // unreadable file" case, same contract as loadOriginal returning null.
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'unreadable.jpg',
          size: 500,
        ),
      ]);
      final item = (await mirror.queryItems())
          .firstWhere((i) => i.localDisplayName == 'unreadable.jpg');

      final result = await service.upload(item);

      expect(result, GalleryUploadResult.deviceFileUnavailable);
      expect(backend.putCalls, isEmpty);
    });
  });

  group('GalleryMirror.recordUploaded', () {
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;

    setUp(() {
      db = GalleryMirrorDatabase(NativeDatabase.memory());
      mirror = GalleryMirror(db);
    });

    tearDown(() async {
      await db.close();
    });

    test('returns false, and marks nothing, when the row no longer matches '
        'the identity the upload started with', () async {
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: 'DCIM/Camera/',
          displayName: 'a.jpg',
          size: 1000,
        ),
      ]);
      final item = (await mirror.queryItems()).single;

      // Simulates a full scan racing the upload and finding the file gone.
      await mirror.applyLocalScan(const []);
      expect(await mirror.totalCount(), 0);

      final marked = await mirror.recordUploaded(item, 'space-a', '/x.jpg');

      expect(marked, isFalse);
      expect(await mirror.totalCount(), 0,
          reason: 'no row should have been resurrected or created');
    });
  });

  group('Ticket 20: verification through the delta feed', () {
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;
    late FakeGalleryUploadBackend backend;
    late FakeLocalSource localSource;
    late GalleryUploadService service;

    setUp(() async {
      db = GalleryMirrorDatabase(NativeDatabase.memory());
      mirror = GalleryMirror(db);
      backend = FakeGalleryUploadBackend();
      localSource = FakeLocalSource();
      service = GalleryUploadService(mirror, backend, localSource);

      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
    });

    tearDown(() async {
      await db.close();
    });

    /// Scans, uploads and returns the resulting (still Device only, pending
    /// verification) item - what every test below drives a feed page against.
    Future<GalleryItem> uploadOnePhoto({
      String relativePath = 'DCIM/Camera/2026/',
      String displayName = 'IMG_0001.jpg',
      Uint8List? bytes,
    }) async {
      final content = bytes ?? _bytesOfLength(4096);
      await mirror.applyLocalScan([
        localMediaItem(
          relativePath: relativePath,
          displayName: displayName,
          size: content.length,
        ),
      ]);
      localSource.setLocalBytes(relativePath, displayName, content);
      final item = (await mirror.queryItems()).single;
      final result = await service.upload(item);
      expect(result, anyOf(GalleryUploadResult.uploaded,
          GalleryUploadResult.alreadyPresent));
      return (await mirror.queryItems()).single;
    }

    test(
        'the delta feed reporting the expected path with the expected '
        'length verifies the item - only then does it become Synced',
        () async {
      final pending = await uploadOnePhoto();
      expect(pending.isAwaitingVerification, isTrue);

      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          GalleryDeltaItem(
            providerId: 'space-a',
            path: '/Photos/Phone/2026/IMG_0001.jpg',
            seq: 1,
            tombstone: false,
            capturedAt: 999999, // deliberately different - must not move it
            size: 4096,
          ),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));

      final verified = (await mirror.queryItems()).single;
      expect(verified.availability, GalleryAvailability.synced,
          reason: 'ticket 20: Seraph independently reported the file at '
              'the expected path with the expected length');
      expect(verified.isAwaitingVerification, isFalse);
      expect(verified.providerId, 'space-a');
      expect(verified.path, '/Photos/Phone/2026/IMG_0001.jpg');
      expect(verified.capturedAt, pending.capturedAt,
          reason: 'a device photo keeps its timeline position when it '
              'becomes Synced');
    });

    test(
        'a photo uploaded under a disambiguated name verifies against the '
        'name it actually went to, not the originally computed one',
        () async {
      backend.seed('space-a', '/Photos/Phone/2026/IMG_0001.jpg',
          _bytesOfLength(100, 0x11));
      final pending = await uploadOnePhoto();
      expect(pending.uploadTargetPath, '/Photos/Phone/2026/IMG_0001 (1).jpg');

      // A feed entry at the ORIGINAL (still-occupied-by-someone-else) path
      // must not verify this item.
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          GalleryDeltaItem(
            providerId: 'space-a',
            path: '/Photos/Phone/2026/IMG_0001.jpg',
            seq: 1,
            tombstone: false,
            capturedAt: 1000,
            size: 100,
          ),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));
      expect((await mirror.queryItems())
              .firstWhere((i) => i.localDisplayName == 'IMG_0001.jpg')
              .isAwaitingVerification,
          isTrue,
          reason: 'a feed entry at a different path must not verify this '
              'item');

      // The feed entry at the disambiguated path DOES verify it.
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          GalleryDeltaItem(
            providerId: 'space-a',
            path: '/Photos/Phone/2026/IMG_0001 (1).jpg',
            seq: 2,
            tombstone: false,
            capturedAt: 1000,
            size: 4096,
          ),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));
      final verified = (await mirror.queryItems())
          .firstWhere((i) => i.localDisplayName == 'IMG_0001.jpg');
      expect(verified.availability, GalleryAvailability.synced);
      expect(verified.path, '/Photos/Phone/2026/IMG_0001 (1).jpg');
    });

    test(
        'a photo whose verification never arrives stays visibly '
        'un-backed-up indefinitely, even as unrelated feed pages are applied',
        () async {
      final pending = await uploadOnePhoto();

      // Pages that say nothing about this item, applied repeatedly - as
      // would happen over many real poll cycles.
      for (var i = 0; i < 3; i++) {
        await mirror.applyPage(GalleryDeltaResponse(
          items: [
            GalleryDeltaItem(
              providerId: 'space-a',
              path: '/Photos/Other/unrelated-$i.jpg',
              seq: i + 1,
              tombstone: false,
              capturedAt: 1,
            ),
          ],
          nextCursor: '',
          hasMore: false,
          nextSince: i + 1,
        ));
      }

      final stillPending = (await mirror.queryItems())
          .firstWhere((i) => i.id == pending.id);
      expect(stillPending.availability, GalleryAvailability.deviceOnly);
      expect(stillPending.isAwaitingVerification, isTrue,
          reason: 'failing in the safe direction: a false alarm, never '
              'false confidence');
    });

    test(
        'a feed entry with a length that contradicts the upload causes the '
        'remote file to be deleted and the upload retried', () async {
      final pending = await uploadOnePhoto();

      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          GalleryDeltaItem(
            providerId: 'space-a',
            path: '/Photos/Phone/2026/IMG_0001.jpg',
            seq: 1,
            tombstone: false,
            capturedAt: 1000,
            size: 1, // contradicts the 4096 bytes this device uploaded
          ),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));

      final mismatched = (await mirror.queryItems())
          .firstWhere((i) => i.id == pending.id);
      expect(mismatched.availability, GalleryAvailability.deviceOnly,
          reason: 'a mismatch must not be mistaken for verification');
      expect(mismatched.isAwaitingVerification, isTrue);

      final needingRetry = await mirror.itemsNeedingUploadRetry();
      expect(needingRetry.map((i) => i.id), [pending.id]);

      final result = await service.retryMismatchedUpload(needingRetry.single);

      expect(backend.removeCalls, [('space-a', '/Photos/Phone/2026/IMG_0001.jpg')],
          reason: 'the untrusted remote file is deleted before the retry');
      expect(result, GalleryUploadResult.uploaded);
      expect(backend.putCalls, hasLength(2),
          reason: 'the original upload plus the retry - the retry landed '
              'back on the same path since the untrusted file was removed '
              'first');
      expect(backend.putCalls.last.$2, '/Photos/Phone/2026/IMG_0001.jpg');

      final retried = (await mirror.queryItems())
          .firstWhere((i) => i.id == pending.id);
      expect(retried.isAwaitingVerification, isTrue,
          reason: 'the retried upload itself is not proof either - it too '
              'awaits the feed');
      expect(await mirror.itemsNeedingUploadRetry(), isEmpty);

      // And the retried upload verifies normally.
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          GalleryDeltaItem(
            providerId: 'space-a',
            path: '/Photos/Phone/2026/IMG_0001.jpg',
            seq: 2,
            tombstone: false,
            capturedAt: 1000,
            size: 4096,
          ),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));
      final verified = (await mirror.queryItems())
          .firstWhere((i) => i.id == pending.id);
      expect(verified.availability, GalleryAvailability.synced);
    });

    test(
        'a photo verified once is not re-verified on every subsequent sync',
        () async {
      final pending = await uploadOnePhoto();
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          GalleryDeltaItem(
            providerId: 'space-a',
            path: '/Photos/Phone/2026/IMG_0001.jpg',
            seq: 1,
            tombstone: false,
            capturedAt: 1000,
            size: 4096,
          ),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));
      final verified = (await mirror.queryItems())
          .firstWhere((i) => i.id == pending.id);
      expect(verified.uploadTargetProviderId, isNull);
      expect(verified.uploadTargetPath, isNull);

      // A later, ordinary metadata refresh for the same (providerId, path) -
      // exactly what a ticket-15-style "existing != null" update looks like.
      // It must not touch [uploadTargetProviderId]/[uploadTargetPath] (both
      // already null) or otherwise re-run verification.
      await mirror.applyPage(GalleryDeltaResponse(
        items: [
          GalleryDeltaItem(
            providerId: 'space-a',
            path: '/Photos/Phone/2026/IMG_0001.jpg',
            seq: 2,
            tombstone: false,
            capturedAt: 1000,
            size: 4096,
            mime: 'image/jpeg',
          ),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 2,
      ));
      final stillVerified = (await mirror.queryItems())
          .firstWhere((i) => i.id == pending.id);
      expect(stillVerified.availability, GalleryAvailability.synced);
      expect(stillVerified.mime, 'image/jpeg');
    });

    test('verification survives an app restart between upload and feed '
        'delivery', () async {
      final pending = await uploadOnePhoto();

      // Simulates an app restart: a fresh GalleryMirror wrapping the same
      // (persisted) database, with no in-process state of its own - exactly
      // what happens on a real device, since nothing about pending
      // verification lives anywhere but the database.
      final restarted = GalleryMirror(db);
      final beforeRestart =
          (await restarted.queryItems()).firstWhere((i) => i.id == pending.id);
      expect(beforeRestart.isAwaitingVerification, isTrue);

      await restarted.applyPage(GalleryDeltaResponse(
        items: [
          GalleryDeltaItem(
            providerId: 'space-a',
            path: '/Photos/Phone/2026/IMG_0001.jpg',
            seq: 1,
            tombstone: false,
            capturedAt: 1000,
            size: 4096,
          ),
        ],
        nextCursor: '',
        hasMore: false,
        nextSince: 1,
      ));

      final verified =
          (await restarted.queryItems()).firstWhere((i) => i.id == pending.id);
      expect(verified.availability, GalleryAvailability.synced);
    });
  });
}
