import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
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
        'byte-identical', () async {
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

      final synced = (await mirror.queryItems()).single;
      expect(synced.availability, GalleryAvailability.synced);
      expect(synced.providerId, 'space-a');
      expect(synced.path, '/Photos/Phone/2026/IMG_0001.jpg',
          reason: 'the path actually used is recorded against the item');
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

      final synced = (await mirror.queryItems()).single;
      expect(synced.path, '/Photos/Phone/2026/IMG_0001 (1).jpg',
          reason: 'the recorded path is the one actually used, not the '
              'originally computed one');
    });

    test(
        'an occupied target path holding content of the same size results in '
        'no upload, and the item is marked synced', () async {
      final bytes = _bytesOfLength(4096, 0x11);
      // Different content, same length - the one case ticket 19 accepts
      // getting wrong.
      backend.seed('space-a', '/Photos/Phone/2026/IMG_0001.jpg',
          _bytesOfLength(4096, 0x99));
      final item = await scanOneDevicePhoto(bytes: bytes);

      final result = await service.upload(item);

      expect(result, GalleryUploadResult.alreadyPresent);
      expect(backend.putCalls, isEmpty, reason: 'no upload should happen');

      final synced = (await mirror.queryItems()).single;
      expect(synced.availability, GalleryAvailability.synced);
      expect(synced.path, '/Photos/Phone/2026/IMG_0001.jpg');
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
      final synced = (await mirror.queryItems()).single;
      expect(synced.availability, GalleryAvailability.synced);
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
}
