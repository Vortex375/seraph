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
  });
}
