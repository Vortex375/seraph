import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:seraph_app/src/gallery/gallery_service.dart';
import 'package:seraph_app/src/gallery/gallery_source_folders_view.dart';

import 'gallery_test_support.dart';

/// Choosing which folders feed Gallery Mode moved out of `gallery_view.dart`
/// when the grid took that route over. The per-folder "Rescan folder" action
/// and its running/finished feedback came with it, and these tests are what
/// keep them from being lost the next time the gallery view is rearranged.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Requests the stubbed backend received, so a test can assert that the
  /// rescan endpoint - not merely a re-read of the list - was called.
  late List<String> posted;

  /// Flipped by the stub to simulate the server-side scan finishing.
  late bool rescanRunning;

  void setUpService() {
    Get.testMode = true;
    Get.reset();
    posted = [];
    rescanRunning = false;

    Map<String, dynamic> folderJson() => {
          'id': 'folder-1',
          'spaceProviderId': 'space-a',
          'path': '/Photos',
          'rescanRunning': rescanRunning,
        };

    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      if (options.method == 'POST') {
        posted.add(options.path);
        rescanRunning = true;
      }
      handler.resolve(Response<Map<String, dynamic>>(
        requestOptions: options,
        data: {
          'sourceFolder': [folderJson()]
        },
      ));
    }));

    Get.put(GalleryService(
      FakeSettingsController(),
      FakeLoginController(),
      dio: dio,
    ));
  }

  tearDown(Get.reset);

  Widget wrap() => const MaterialApp(home: GallerySourceFoldersView());

  /// Pumps far enough for a stubbed HTTP round trip and the rebuild it causes,
  /// but not far enough to reach the next rescan poll.
  ///
  /// `pumpAndSettle` is unusable while a rescan is running: the poll
  /// re-arms itself for as long as the server reports the scan going, so
  /// there is no frame at which the tree settles.
  Future<void> pumpBriefly(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('every folder offers a Rescan folder action', (tester) async {
    setUpService();
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('/space-a/Photos'), findsOneWidget);
    expect(find.byTooltip('Rescan folder'), findsOneWidget);
  });

  testWidgets('rescanning tells the user it started and then that it finished',
      (tester) async {
    setUpService();
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Rescan folder'));
    await pumpBriefly(tester);

    expect(posted, ['/api/gallery/source-folders/folder-1/rescan'],
        reason: 'the action must trigger a real re-scan, not a list refresh');
    expect(find.textContaining('Rescanning /space-a/Photos'), findsOneWidget);

    // While it runs, the row itself says so and offers no second rescan.
    expect(find.text('Rescanning…'), findsOneWidget);
    expect(find.byTooltip('Rescan folder'), findsNothing);

    // The server finishes; the app learns this by polling the folder list.
    rescanRunning = false;
    await tester.pump(const Duration(seconds: 3));
    await pumpBriefly(tester);

    expect(find.text('Rescanning…'), findsNothing);
    expect(find.byTooltip('Rescan folder'), findsOneWidget);

    // The "started" message has to time out before the "finished" one gets
    // its turn on screen.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.textContaining('Rescan of /space-a/Photos finished'),
        findsOneWidget);

    // Let it time out too, so no timer outlives the test.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });
}
