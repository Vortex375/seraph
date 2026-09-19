import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:seraph_app/src/file_browser/file_browser_controller.dart';
import 'package:seraph_app/src/file_browser/file_browser_view.dart';
import 'package:seraph_app/src/file_viewer/file_viewer_view.dart';
import 'package:seraph_app/src/gallery/gallery_grid_controller.dart';
import 'package:seraph_app/src/gallery/gallery_image_loader.dart';
import 'package:seraph_app/src/gallery/gallery_photo_viewer.dart';
import 'package:seraph_app/src/gallery/gallery_tile.dart';
import 'package:seraph_app/src/gallery/gallery_view.dart';
import 'package:seraph_app/src/gallery/hdr_photo_view.dart';
import 'package:seraph_app/src/gallery/local/local_image_loader.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/share/share_controller.dart';

import 'gallery_test_support.dart';

/// Covers the gallery photo viewer's native HDR path (`.scratch/hdr-photo-
/// viewer/spec.md`) at its one Dart-side seam, the way the spec's "Testing
/// Decisions" ask: the [HdrPhotoView] host widget is driven through fake
/// platform channels - the `flutter/platform_views` channel stands in for
/// the engine's platform-view registry, `seraph/local_media` records the
/// colour-mode calls, and the per-view `seraph/hdr_photo/view/<id>` channel
/// carries the native reports (zoom, tap, decode error). The native Kotlin
/// side itself is device-gated and has no automation - its acceptance is the
/// spec's recorded device checklist.
///
/// Everything here runs on the test host with the real platform gate false;
/// [hdrPhotoNativeForTest] forces the native path on per test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const platformViews = MethodChannel('flutter/platform_views');
  const localMedia = MethodChannel('seraph/local_media');

  late GalleryMirrorDatabase db;
  late GalleryGridController controller;

  /// `setHdrColorMode` calls the native side received, in order.
  final colorModeCalls = <bool>[];

  /// The platform view id the (faked) engine assigned, once created.
  int? createdViewId;

  /// When non-null, the fake dio holds every full-resolution request until
  /// completed - the "slow download" of a cloud photo.
  Completer<void>? holdFetch;

  /// When true, the fake dio fails every full-resolution request.
  bool failFetch = false;

  setUp(() {
    hdrPhotoNativeForTest = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(localMedia, (call) async {
      if (call.method == 'setHdrColorMode') {
        colorModeCalls.add(call.arguments as bool);
      }
      // Everything else (setBrightnessBoost) is accepted and ignored.
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platformViews, (call) async {
      switch (call.method) {
        case 'create':
          createdViewId = (call.arguments as Map)['id'] as int;
          return null;
        case 'resize':
          final args = call.arguments as Map;
          return {'width': args['width'], 'height': args['height']};
        default:
          return null;
      }
    });
  });

  tearDown(() async {
    // Release a held fetch so its future settles before the reset.
    final fetch = holdFetch;
    if (fetch != null && !fetch.isCompleted) {
      fetch.complete();
    }
    hdrPhotoNativeForTest = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(localMedia, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(platformViews, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await db.close();
    Get.reset();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    colorModeCalls.clear();
    createdViewId = null;
    holdFetch = null;
    failFetch = false;
  });

  /// Three cloud-only photos (no Local Source), each with its 512px
  /// thumbnail already in the mirror's cache so the thumbnail layer renders
  /// without the network - exactly the state of a photo the grid has shown.
  Future<void> setUpGallery() async {
    Get.testMode = true;
    Get.reset();

    db = openTestMirrorDatabase();
    final mirror = GalleryMirror(db);
    for (var i = 0; i < 3; i++) {
      final path = '/Photos/photo-$i.jpg';
      await insertMirrorItem(db,
          path: path, capturedAt: 1770000000 - i * 86400);
      await db.into(db.cachedThumbnails).insertOnConflictUpdate(
            CachedThumbnailsCompanion.insert(
              providerId: 'space-a',
              path: path,
              size: galleryThumbnailSize,
              bytes: onePixelPng,
              fetchedAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
    }

    final dio = Dio();
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      final hold = holdFetch;
      if (hold != null) {
        await hold.future;
      }
      if (failFetch) {
        handler.reject(DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
        ));
      } else {
        handler.resolve(Response(requestOptions: options, data: onePixelPng));
      }
    }));

    Get.put<ShareController>(FakeShareController());
    Get.put<SettingsController>(FakeSettingsController());
    Get.put<LoginController>(FakeLoginController());
    Get.put(FileBrowserController());
    Get.put(GalleryImageLoader(
      Get.find<SettingsController>(),
      Get.find<LoginController>(),
      db,
      dio: dio,
    ));
    // No Local Source: every photo here is cloud-only.
    Get.put(LocalImageLoader(null));
    controller = GalleryGridController(mirror: mirror, localScanService: null);
    Get.put(controller);
    await controller.open();
  }

  Widget wrap() {
    return GetMaterialApp(
      initialRoute: GalleryView.routeName,
      getPages: [
        GetPage(
          name: GalleryView.routeName,
          page: () => const GalleryView(),
        ),
        GetPage(
          name: GalleryPhotoViewerView.routeName,
          page: () => GalleryPhotoViewerView(
            initialIndex: int.tryParse(Get.parameters['index'] ?? '') ?? 0,
          ),
        ),
        GetPage(
          name: FileBrowserView.routeName,
          page: () => const Scaffold(body: SizedBox.shrink()),
        ),
        GetPage(
          name: FileViewerView.routeName,
          page: () => const Scaffold(body: SizedBox.shrink()),
        ),
      ],
    );
  }

  Future<void> openViewer(WidgetTester tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    await tester.tap(find.byType(GalleryTile).first);
    await tester.pumpAndSettle();
  }

  /// Simulates a native-to-Dart report on the per-view channel.
  Future<void> sendNativeCall(MethodCall call) async {
    expect(createdViewId, isNotNull,
        reason: 'the platform view must be created before the native side '
            'can report');
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      'seraph/hdr_photo/view/$createdViewId',
      const StandardMethodCodec().encodeMethodCall(call),
      (_) {},
    );
  }

  /// The page's 512px thumbnail layer - the same cached provider the grid
  /// warmed, distinguishable from any full-resolution decode by its size.
  Finder thumbnail() => find.byWidgetPredicate(
        (widget) =>
            widget is Image &&
            widget.image is GalleryImage &&
            (widget.image as GalleryImage).size == galleryThumbnailSize,
      );

  testWidgets(
      'the page shows the thumbnail until the native view is ready, '
      'then swaps to it', (tester) async {
    holdFetch = Completer<void>();
    await setUpGallery();
    await openViewer(tester);

    // The full-resolution bytes are still "downloading": the thumbnail
    // holds the frame, and no platform view exists yet.
    expect(find.byType(HdrPhotoView), findsNothing);
    expect(thumbnail(), findsOneWidget);

    holdFetch!.complete();
    await tester.pumpAndSettle();

    expect(find.byType(HdrPhotoView), findsOneWidget);
  });

  testWidgets('the native zoom report is what gates the pager physics',
      (tester) async {
    await setUpGallery();
    await openViewer(tester);
    final page = find.byType(PageView);
    expect(tester.widget<PageView>(page).physics, isA<PageScrollPhysics>());

    await sendNativeCall(const MethodCall('zoomChanged', true));
    await tester.pump();
    expect(tester.widget<PageView>(page).physics,
        isA<NeverScrollableScrollPhysics>(),
        reason: 'zoomed in, the pager must not page');

    await sendNativeCall(const MethodCall('zoomChanged', false));
    await tester.pump();
    expect(tester.widget<PageView>(page).physics, isA<PageScrollPhysics>(),
        reason: 'zoom-out must re-enable paging immediately');
  });

  testWidgets('the native tap report toggles the chrome', (tester) async {
    final uiModeCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
        uiModeCalls.add(call);
      }
      return null;
    });
    await setUpGallery();
    await openViewer(tester);
    expect(find.byType(AppBar), findsOneWidget);

    await sendNativeCall(const MethodCall('tap'));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsNothing,
        reason: 'a tap on the photo must hide the app bar');
    expect(uiModeCalls.last.arguments.toString(), contains('immersive'));

    await sendNativeCall(const MethodCall('tap'));
    await tester.pumpAndSettle();
    expect(find.byType(AppBar), findsOneWidget);
  });

  testWidgets(
      'a native decode error shows the existing error state and '
      'restores the colour mode', (tester) async {
    await setUpGallery();
    await openViewer(tester);
    expect(find.byType(HdrPhotoView), findsOneWidget);
    colorModeCalls.clear();

    await sendNativeCall(const MethodCall('decodeError'));
    await tester.pumpAndSettle();

    expect(find.byType(HdrPhotoView), findsNothing);
    // Cloud-only photo: the existing error state leaves its thumbnail
    // showing - never a blank page.
    expect(thumbnail(), findsOneWidget);
    // The host went away, so the last colour-mode call restores default.
    expect(colorModeCalls, [false]);
  });

  testWidgets(
      'a failed download shows the error state and the viewer keeps '
      'working', (tester) async {
    failFetch = true;
    await setUpGallery();
    await openViewer(tester);

    expect(find.byType(HdrPhotoView), findsNothing);
    expect(thumbnail(), findsOneWidget);

    // The viewer is not stuck: the next page still pages in.
    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(
      tester.widget<PageView>(find.byType(PageView)).controller!.page!.round(),
      1,
    );
  });

  testWidgets('a 1x horizontal swipe pages photo-by-photo on the native path',
      (tester) async {
    await setUpGallery();
    await openViewer(tester);

    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();

    expect(
      tester.widget<PageView>(find.byType(PageView)).controller!.page!.round(),
      1,
    );
    // The new page renders natively too.
    expect(find.byType(HdrPhotoView), findsOneWidget);
  });

  testWidgets(
      'opening the viewer sets the colour mode to HDR and exiting '
      'restores it', (tester) async {
    await setUpGallery();
    await openViewer(tester);

    expect(colorModeCalls, [true],
        reason: 'the viewer must put the window in HDR colour mode');
    colorModeCalls.clear();

    Get.back<void>();
    await tester.pumpAndSettle();

    expect(find.byType(GalleryPhotoViewerView), findsNothing);
    expect(colorModeCalls, [false],
        reason: 'the last host closing must restore the default colour mode');
  });
}
