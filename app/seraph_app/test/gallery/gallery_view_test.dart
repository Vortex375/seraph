import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:seraph_app/src/gallery/gallery_grid_controller.dart';
import 'package:seraph_app/src/gallery/gallery_image_loader.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
import 'package:seraph_app/src/gallery/gallery_photo_viewer.dart';
import 'package:seraph_app/src/gallery/gallery_tile.dart';
import 'package:seraph_app/src/gallery/gallery_view.dart';
import 'package:seraph_app/src/gallery/local/local_image_loader.dart';
import 'package:seraph_app/src/gallery/local/local_scan_service.dart';
import 'package:seraph_app/src/gallery/local/local_source.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/share/share_controller.dart';

import 'gallery_test_support.dart';

/// Widget tests here assert *rendering* against a pre-populated mirror. What
/// the gallery shows, in what order, and how much of it, is decided by
/// [GalleryGridController] and tested at that seam in
/// `gallery_grid_controller_test.dart`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late GalleryMirrorDatabase db;
  late GalleryMirror mirror;
  late GalleryGridController controller;

  Future<void> setUpGallery({int itemCount = 0, FakeLocalSource? localSource}) async {
    Get.testMode = true;
    Get.reset();

    db = openTestMirrorDatabase();
    mirror = GalleryMirror(db);
    if (itemCount > 0) {
      await populateMirror(db, count: itemCount);
    }

    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      handler.resolve(Response(requestOptions: options, data: onePixelPng));
    }));

    Get.put<ShareController>(FakeShareController());
    Get.put<SettingsController>(FakeSettingsController());
    Get.put<LoginController>(FakeLoginController());
    Get.put(GalleryImageLoader(
      Get.find<SettingsController>(),
      Get.find<LoginController>(),
      db,
      dio: dio,
    ));
    Get.put(LocalImageLoader(localSource));

    controller = GalleryGridController(
      mirror: mirror,
      localScanService: localSource == null
          ? null
          : LocalScanService(mirror, localSource: localSource),
    );
    Get.put(controller);
    await controller.open();
  }

  tearDown(() async {
    await db.close();
    Get.reset();
    // Flutter's ImageCache is a process-wide singleton, not scoped to a
    // test: two tests using the same device-photo identity (relativePath,
    // displayName, tile size) would otherwise see the second one silently
    // reuse the first's cached decode and never call the Local Source at
    // all - exactly the false pass ticket 28's tests would produce without
    // this.
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  Widget wrap() {
    return GetMaterialApp(
      home: const GalleryView(),
      getPages: [
        GetPage(
          name: GalleryPhotoViewerView.routeName,
          page: () => GalleryPhotoViewerView(
            initialIndex: int.tryParse(Get.parameters['index'] ?? '') ?? 0,
          ),
        ),
      ],
    );
  }

  /// The grid's column count comes from the width it is actually laid out in,
  /// so a test about layout has to change the surface, not just MediaQuery.
  Future<void> useWindow(WidgetTester tester, Size size) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  testWidgets('an empty gallery explains itself and offers folder setup',
      (tester) async {
    await setUpGallery();
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.textContaining('No photos in your gallery yet'), findsOneWidget);
    expect(find.text('Choose folders'), findsOneWidget);
  });

  testWidgets('the grid shows a tile per item, newest first', (tester) async {
    await setUpGallery(itemCount: 12);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(controller.totalCount.value, 12);
    // Only the on-screen tiles are built - the grid is lazy - so assert that
    // some tiles rendered and that the first one is the newest item.
    expect(find.byType(GalleryTile), findsWidgets);

    final firstTile = tester.widgetList<GalleryTile>(find.byType(GalleryTile)).first;
    expect(firstTile.item!.path, controller.itemAt(0)!.path);
  });

  testWidgets('a date heading says roughly where in history the user is',
      (tester) async {
    await setUpGallery(itemCount: 30);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    final newest = controller.knownDateAt(0)!;
    final expected =
        '${_monthName(newest.month)} ${newest.year}';
    expect(find.text(expected), findsOneWidget);
  });

  testWidgets('a scrubber is available to jump to a point in time',
      (tester) async {
    await setUpGallery(itemCount: 60);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    final handle = find.byKey(const Key('gallery-scrubber-handle'));
    expect(handle, findsOneWidget);

    final before = tester.getTopLeft(handle).dy;
    await tester.drag(handle, const Offset(0, 400));
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(handle).dy, greaterThan(before),
        reason: 'dragging the scrubber must move it, and the grid with it');
  });

  testWidgets('an unsupported photo shows a placeholder with the reason',
      (tester) async {
    await setUpGallery();
    await insertMirrorItem(db,
        path: '/Photos/raw.dng', capturedAt: 1770000000, unsupported: 'format');
    await controller.reload();

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('This file format cannot be displayed'), findsOneWidget);
  });

  testWidgets('tapping a photo opens it full screen', (tester) async {
    await setUpGallery(itemCount: 6);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(GalleryTile).first);
    await tester.pumpAndSettle();

    expect(find.byType(GalleryPhotoViewerView), findsOneWidget);
    expect(Get.currentRoute, startsWith(GalleryPhotoViewerView.routeName));
    expect(Get.parameters['index'], '0');
  });

  testWidgets('the viewer swipes through photos in the grid order',
      (tester) async {
    await setUpGallery(itemCount: 6);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(GalleryTile).first);
    await tester.pumpAndSettle();

    // The viewer pages over the same list, so page N is grid index N.
    final page = find.byType(PageView);
    expect(page, findsOneWidget);
    expect(tester.widget<PageView>(page).controller!.initialPage, 0);

    await tester.fling(page, const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();

    expect(tester.widget<PageView>(page).controller!.page!.round(), 1);
  });

  testWidgets("a photo's details name the Seraph folder it lives in",
      (tester) async {
    await setUpGallery();
    await insertMirrorItem(db,
        providerId: 'family-space',
        path: '/Holidays/Crete/beach.jpg',
        capturedAt: 1770000000);
    await controller.reload();

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(GalleryTile).first);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Photo details'));
    await tester.pumpAndSettle();

    expect(find.text('Seraph folder'), findsOneWidget);
    expect(find.text('/family-space/Holidays/Crete'), findsOneWidget);
  });

  testWidgets('an unsupported photo full screen says why', (tester) async {
    await setUpGallery();
    await insertMirrorItem(db,
        path: '/Photos/broken.jpg',
        capturedAt: 1770000000,
        unsupported: 'corrupt');
    await controller.reload();

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(GalleryTile).first);
    await tester.pumpAndSettle();

    expect(find.text('broken.jpg'), findsOneWidget);
    expect(find.textContaining('truncated or corrupt'), findsWidgets);
  });

  testWidgets('the gallery offers nothing to upload with', (tester) async {
    await setUpGallery(itemCount: 6);
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // Nothing on any platform this build ships to can put a photo into
    // Seraph from Gallery Mode, so there is no control that says it can.
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byIcon(Icons.upload), findsNothing);
    expect(find.byIcon(Icons.backup), findsNothing);
    expect(find.byIcon(Icons.add_a_photo), findsNothing);
    expect(find.textContaining('Upload'), findsNothing);
    expect(find.textContaining('Back up'), findsNothing);
    expect(find.textContaining('Free up space'), findsNothing);
  });

  testWidgets('the same view renders at a desktop or web window size',
      (tester) async {
    await setUpGallery(itemCount: 40);
    await useWindow(tester, const Size(1400, 900));
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(GalleryTile), findsWidgets);
    expect(find.byKey(const Key('gallery-scrubber-handle')), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);

    // A wider window means more columns, not bigger tiles.
    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, greaterThan(4));
  });

  group('photo-access UI (ticket 16)', () {
    testWidgets('with full access, no permission banner is shown',
        (tester) async {
      await setUpGallery(
        itemCount: 3,
        localSource: FakeLocalSource(const [], LocalPermissionStatus.granted),
      );
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('gallery-partial-access-banner')),
          findsNothing);
      expect(find.textContaining('Limited photo access'), findsNothing);
      expect(find.textContaining('everything is backed up'), findsNothing);
    });

    testWidgets('with no Local Source at all, no permission banner is shown',
        (tester) async {
      await setUpGallery(itemCount: 3);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('gallery-partial-access-banner')),
          findsNothing);
      expect(find.textContaining('Allow access'), findsNothing);
    });

    testWidgets('a partial grant shows a persistent warning that cannot be '
        'dismissed', (tester) async {
      await setUpGallery(
        itemCount: 2,
        localSource: FakeLocalSource(const [], LocalPermissionStatus.partial),
      );
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      final banner = find.byKey(const Key('gallery-partial-access-banner'));
      expect(banner, findsOneWidget);
      expect(find.textContaining("don't include the"), findsOneWidget);
      // No close/dismiss affordance on the warning itself.
      expect(
          find.descendant(of: banner, matching: find.text('Not now')),
          findsNothing);
    });

    testWidgets(
        'a partial grant offers both extending the selection and full '
        'access', (tester) async {
      final source = FakeLocalSource(const [], LocalPermissionStatus.partial);
      await setUpGallery(itemCount: 1, localSource: source);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Choose more photos'));
      await tester.pumpAndSettle();
      expect(source.requestCount, 1);

      await tester.tap(find.text('Allow full access'));
      await tester.pumpAndSettle();
      expect(source.openSettingsCount, 1);
    });

    testWidgets(
        'a partial grant\'s summary states what it cannot see rather than '
        'implying completeness', (tester) async {
      await setUpGallery(
        itemCount: 2,
        localSource: FakeLocalSource(const [], LocalPermissionStatus.partial),
      );
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(
          find.textContaining("Does not count device photos outside your "
              "selection"),
          findsOneWidget);
    });

    testWidgets(
        'a denied grant explains itself before offering to request access '
        'again', (tester) async {
      await setUpGallery(
        itemCount: 2,
        localSource: FakeLocalSource(const [], LocalPermissionStatus.denied),
      );
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // The explanation is on screen before the request button is ever
      // pressed - ticket 16's "preceded by an explanation" criterion.
      expect(find.textContaining('back up photos on this device'),
          findsOneWidget);
      final requestButton = find.text('Allow access');
      expect(requestButton, findsOneWidget);

      await tester.tap(requestButton);
      await tester.pumpAndSettle();
      // The gallery is still fully usable either way.
      expect(find.byType(GalleryTile), findsWidgets);
    });

    testWidgets('dismissing the denied-access prompt hides it for this open',
        (tester) async {
      await setUpGallery(
        itemCount: 1,
        localSource: FakeLocalSource(const [], LocalPermissionStatus.denied),
      );
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.text('Allow access'), findsOneWidget);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      expect(find.text('Allow access'), findsNothing);
      // Cloud-only gallery keeps working regardless.
      expect(find.byType(GalleryTile), findsWidgets);
    });
  });

  group('device photo previews (ticket 28)', () {
    testWidgets(
        'a Device only photo renders its actual image in the grid, not a '
        'placeholder', (tester) async {
      final source = FakeLocalSource([
        localMediaItem(
            relativePath: 'DCIM/Camera/',
            displayName: 'device.jpg',
            size: 2048,
            dateTakenMillis: 1700000000000),
      ]);
      source.setLocalBytes('DCIM/Camera/', 'device.jpg', onePixelPng);
      await setUpGallery(localSource: source);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(controller.itemAt(0)!.availability, GalleryAvailability.deviceOnly);
      final images = tester.widgetList<Image>(find.byType(Image));
      expect(images.any((img) => img.image is LocalGalleryImage), isTrue,
          reason: 'the tile must ask the Local Source seam for pixels');
      // The availability badge is the ONLY smartphone icon on screen - the
      // placeholder's own smartphone icon would make this two.
      expect(find.byIcon(Icons.smartphone_outlined), findsOneWidget);
      expect(source.thumbnailCalls, isNotEmpty);
      final call = source.thumbnailCalls.first;
      expect(call.$1, 'DCIM/Camera/');
      expect(call.$2, 'device.jpg');
      expect(call.$3, greaterThan(0));
      expect(call.$4, call.$3,
          reason: 'a square tile requests a square thumbnail');
    });

    testWidgets(
        'a Device only photo renders its full image in the full-screen '
        'viewer', (tester) async {
      final source = FakeLocalSource([
        localMediaItem(
            relativePath: 'DCIM/Camera/',
            displayName: 'device.jpg',
            size: 2048,
            dateTakenMillis: 1700000000000),
      ]);
      source.setLocalBytes('DCIM/Camera/', 'device.jpg', onePixelPng);
      await setUpGallery(localSource: source);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      await tester.tap(find.byType(GalleryTile).first);
      await tester.pumpAndSettle();

      expect(find.text('This photo is only on this device'), findsNothing);
      final images = tester.widgetList<Image>(find.byType(Image));
      final fullRes = images.where((img) =>
          img.image is LocalGalleryImage &&
          (img.image as LocalGalleryImage).width == null);
      expect(fullRes, isNotEmpty,
          reason: 'the viewer must ask for the original, not a thumbnail');
      expect(source.originalCalls, isNotEmpty);
      expect(source.originalCalls.first, ('DCIM/Camera/', 'device.jpg'));
    });

    testWidgets(
        'a Synced photo renders from the device copy when it can be read',
        (tester) async {
      final source = FakeLocalSource();
      await setUpGallery(localSource: source);
      await insertMirrorItem(db,
          path: '/Photos/synced.jpg', capturedAt: 1770000000, size: 2048);
      await mirror.applyLocalScan([
        localMediaItem(
            relativePath: 'DCIM/Camera/',
            displayName: 'synced.jpg',
            size: 2048,
            dateTakenMillis: 1770000000 * 1000),
      ]);
      source.setLocalBytes('DCIM/Camera/', 'synced.jpg', onePixelPng);
      await controller.reload();

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(controller.itemAt(0)!.availability, GalleryAvailability.synced);
      expect(source.thumbnailCalls, isNotEmpty,
          reason: 'the device copy must be tried first');
      final images = tester.widgetList<Image>(find.byType(Image));
      expect(images.any((img) => img.image is LocalGalleryImage), isTrue);
    });

    testWidgets(
        'a Synced photo falls back to the cloud thumbnail when the device '
        'copy cannot be read', (tester) async {
      final source = FakeLocalSource();
      await setUpGallery(localSource: source);
      await insertMirrorItem(db,
          path: '/Photos/synced.jpg', capturedAt: 1770000000, size: 2048);
      await mirror.applyLocalScan([
        localMediaItem(
            relativePath: 'DCIM/Camera/',
            displayName: 'synced.jpg',
            size: 2048,
            dateTakenMillis: 1770000000 * 1000),
      ]);
      // Deliberately never calling setLocalBytes: the device copy cannot be
      // produced, exactly as a decode failure or a deleted file would look.
      await controller.reload();

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      // The cloud fallback is a second, chained image load - kicked off
      // only once the device copy's own load has already failed - so it
      // needs a settle pass of its own rather than assuming the first one
      // caught it too.
      await tester.pumpAndSettle();

      expect(controller.itemAt(0)!.availability, GalleryAvailability.synced);
      expect(source.thumbnailCalls, isNotEmpty,
          reason: 'the device copy must be tried first');
      final images = tester.widgetList<Image>(find.byType(Image));
      // The failed Image widget's own configuration is unchanged by
      // errorBuilder (only what it renders changes), so it still appears in
      // the tree alongside whatever errorBuilder produced - what matters is
      // that the cloud image (wrapped in a ResizeImage to decode at tile
      // size, see GalleryTile._cloudThumbnail) is what actually got built.
      expect(
          images.any((img) =>
              img.image is ResizeImage &&
              (img.image as ResizeImage).imageProvider is GalleryImage),
          isTrue,
          reason: 'a failed device read must fall back to the cloud image');
      // No unsupported-format icon: this is a fallback, not a cloud-side
      // decode error.
      expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a Cloud only photo renders exactly as before this ticket - '
        'no Local Source call is ever made for it', (tester) async {
      final source = FakeLocalSource();
      await setUpGallery(itemCount: 3, localSource: source);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(source.thumbnailCalls, isEmpty);
      expect(source.originalCalls, isEmpty);
      final images = tester.widgetList<Image>(find.byType(Image));
      expect(images.any((img) => img.image is LocalGalleryImage), isFalse);
    });

    testWidgets(
        'a photo that cannot be decoded falls back to the placeholder for '
        'that tile alone, leaving the rest of the grid intact', (tester) async {
      final source = FakeLocalSource([
        localMediaItem(
            relativePath: 'DCIM/Camera/',
            displayName: 'broken.jpg',
            size: 99,
            dateTakenMillis: 1700000001000),
        localMediaItem(
            relativePath: 'DCIM/Camera/',
            displayName: 'fine.jpg',
            size: 100,
            dateTakenMillis: 1700000002000),
      ]);
      // Only 'fine.jpg' can produce bytes - 'broken.jpg' simulates a corrupt
      // file the platform's own decoder rejects.
      source.setLocalBytes('DCIM/Camera/', 'fine.jpg', onePixelPng);
      await setUpGallery(localSource: source);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(controller.totalCount.value, 2);
      expect(tester.takeException(), isNull);
      // The unreadable item's placeholder still carries its file name.
      expect(find.byTooltip('broken.jpg'), findsOneWidget);
    });

    testWidgets(
        'a photo deleted from the device between the scan and the render '
        'fails to the same placeholder rather than throwing', (tester) async {
      final source = FakeLocalSource([
        localMediaItem(
            relativePath: 'DCIM/Camera/',
            displayName: 'vanished.jpg',
            size: 50,
            dateTakenMillis: 1700000000000),
      ]);
      source.setLocalBytes('DCIM/Camera/', 'vanished.jpg', onePixelPng);
      // Withdrawn before the scan even applies - simulating a file gone by
      // the time anything asks to render it.
      source.forgetLocalBytes('DCIM/Camera/', 'vanished.jpg');
      await setUpGallery(localSource: source);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.byTooltip('vanished.jpg'), findsOneWidget);
    });

    testWidgets(
        'under a partial grant, a photo the app was given renders normally '
        'with no error shown', (tester) async {
      final source = FakeLocalSource(
        [
          localMediaItem(
              relativePath: 'DCIM/Camera/',
              displayName: 'selected.jpg',
              size: 2048,
              dateTakenMillis: 1700000000000),
        ],
        LocalPermissionStatus.partial,
      );
      source.setLocalBytes('DCIM/Camera/', 'selected.jpg', onePixelPng);
      await setUpGallery(localSource: source);
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final images = tester.widgetList<Image>(find.byType(Image));
      expect(images.any((img) => img.image is LocalGalleryImage), isTrue);
      expect(find.byIcon(Icons.image_not_supported_outlined), findsNothing);
    });
  });

  testWidgets('a narrow phone window keeps a usable column count',
      (tester) async {
    await setUpGallery(itemCount: 20);
    await useWindow(tester, const Size(360, 800));
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    final grid = tester.widget<GridView>(find.byType(GridView));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, inInclusiveRange(2, 4));
  });
}

String _monthName(int month) => const [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ][month - 1];
