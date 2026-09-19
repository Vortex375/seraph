import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response, Value;
import 'package:seraph_app/src/gallery/gallery_service.dart';
import 'package:seraph_app/src/gallery/gallery_source_folders_view.dart';
import 'package:seraph_app/src/gallery/local/local_scan_service.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/sync/gallery_data_sync_controller.dart';

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

  /// Ticket 29: registers a Local Source alongside the cloud service, so the
  /// screen's *On this device* section has something to show. Left
  /// unregistered by [setUpService] alone, which is what the "no device
  /// section" tests rely on.
  GalleryMirrorDatabase? mirrorDb;
  late GalleryMirror mirror;

  void setUpServiceWithLocalSource() {
    setUpService();
    final db = GalleryMirrorDatabase(NativeDatabase.memory());
    mirrorDb = db;
    mirror = GalleryMirror(db);
    Get.put(mirror);
    Get.put(LocalScanService(mirror, localSource: FakeLocalSource()));
  }

  tearDown(() async {
    Get.reset();
    await mirrorDb?.close();
    mirrorDb = null;
  });

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

  // Ticket 29: the *On this device* section.
  group('Local Folders', () {
    testWidgets(
        'the device section is absent entirely where there is no Local '
        'Source, rather than present and empty', (tester) async {
      setUpService();
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.text('On this device'), findsNothing);
    });

    testWidgets(
        'lists the device\'s folders with their photo counts, defaulting '
        'DCIM to selected and everything else to not', (tester) async {
      setUpServiceWithLocalSource();
      await mirror.applyLocalScan([
        localMediaItem(
            relativePath: 'DCIM/Camera/', displayName: 'a.jpg', size: 1),
        localMediaItem(
            relativePath: 'DCIM/Camera/', displayName: 'b.jpg', size: 2),
        localMediaItem(
            relativePath: 'Pictures/Screenshots/',
            displayName: 'c.jpg',
            size: 3),
      ]);

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.text('On this device'), findsOneWidget);
      expect(find.text('DCIM/Camera/'), findsOneWidget);
      expect(find.text('2 photos'), findsOneWidget);
      expect(find.text('Pictures/Screenshots/'), findsOneWidget);
      expect(find.text('1 photo'), findsOneWidget);

      final dcimSwitch = tester.widget<Switch>(find.descendant(
          of: find.ancestor(
              of: find.text('DCIM/Camera/'), matching: find.byType(ListTile)),
          matching: find.byType(Switch)));
      expect(dcimSwitch.value, isTrue, reason: 'DCIM is selected by default');

      final screenshotsSwitch = tester.widget<Switch>(find.descendant(
          of: find.ancestor(
              of: find.text('Pictures/Screenshots/'),
              matching: find.byType(ListTile)),
          matching: find.byType(Switch)));
      expect(screenshotsSwitch.value, isFalse,
          reason: 'not under DCIM, so unselected by default');
    });

    testWidgets(
        'deselecting a folder takes effect immediately and the folder stays '
        'listed, ready to be selected again', (tester) async {
      setUpServiceWithLocalSource();
      await mirror.applyLocalScan([
        localMediaItem(relativePath: 'DCIM/Camera/', displayName: 'a.jpg'),
      ]);

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      final dcimSwitchFinder = find.descendant(
          of: find.ancestor(
              of: find.text('DCIM/Camera/'), matching: find.byType(ListTile)),
          matching: find.byType(Switch));
      expect(tester.widget<Switch>(dcimSwitchFinder).value, isTrue);

      await tester.tap(dcimSwitchFinder);
      await tester.pumpAndSettle();

      // Still listed...
      expect(find.text('DCIM/Camera/'), findsOneWidget);
      // ...but now off, and the mirror agrees immediately - no rescan.
      expect(tester.widget<Switch>(dcimSwitchFinder).value, isFalse);
      expect((await mirror.listLocalFolders()).single.selected, isFalse);
      expect(await mirror.totalCount(), 0,
          reason: 'the deselected folder\'s only photo must be gone from '
              'the merged gallery right away');
    });
  });

  // Ticket 18: the *Sync Pairs* section.
  group('Sync Pairs', () {
    testWidgets(
        'the Sync Pairs section is absent entirely where there is no Local '
        'Source, exactly like the device section it lives beside',
        (tester) async {
      setUpService();
      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.text('Sync Pairs'), findsNothing);
    });

    testWidgets(
        'lists what each pair maps to and how many photos it covers',
        (tester) async {
      setUpServiceWithLocalSource();
      await mirror.applyLocalScan([
        localMediaItem(
            relativePath: 'DCIM/Camera/', displayName: 'a.jpg', size: 1),
        localMediaItem(
            relativePath: 'DCIM/Camera/', displayName: 'b.jpg', size: 2),
      ]);
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.text('Sync Pairs'), findsOneWidget);
      expect(find.text('DCIM/Camera/ -> /space-a/Photos/Phone'),
          findsOneWidget);
      expect(find.text('2 photos covered'), findsOneWidget);
    });

    testWidgets(
        'removing a Sync Pair takes it out of the list and the mirror, '
        'without touching Gallery Source Folders', (tester) async {
      setUpServiceWithLocalSource();
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      expect(find.text('DCIM/Camera/ -> /space-a/Photos/Phone'),
          findsOneWidget);

      await tester.tap(find.byTooltip('Remove Sync Pair'));
      await tester.pumpAndSettle();
      // Confirmation dialog.
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await tester.pumpAndSettle();

      expect(find.text('DCIM/Camera/ -> /space-a/Photos/Phone'),
          findsNothing);
      expect(await mirror.listSyncPairs(), isEmpty);
      // The In Seraph folder list is untouched - removing a pair never
      // removes the Gallery Source Folder it created (D18).
      expect(posted, isEmpty);
    });

    // Ticket 21: retargeting. Like the add-Sync-Pair flow (ticket 18's own
    // note on this file), the nested FolderPickerDialog-then-confirm flow is
    // not driven end to end here - it would need a stubbed WebDAV
    // FileService, which nothing in this file sets up. Retarget's actual
    // effect on the mirror (old target kept as history, new target used for
    // new uploads) is covered at the mirror seam instead
    // (`gallery_sync_pair_retarget_test.dart`); this just checks the action
    // is wired into the tile.
    testWidgets('a Sync Pair tile offers Retarget alongside Remove',
        (tester) async {
      setUpServiceWithLocalSource();
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      expect(find.byTooltip('Retarget Sync Pair'), findsOneWidget);
    });
  });

  // The failure list can grow to thousands of items when many uploads
  // permanently fail. It MUST be virtualized - only the rows actually on
  // screen are built - or the whole page freezes (Android shows the
  // "unresponsive app" dialog). A non-virtualized Column would build every
  // Retry button in one frame; a SliverList.builder builds only the
  // screenful plus cacheExtent.
  group('Backup failure list', () {
    testWidgets(
        'virtualizes a large failure list so only a screenful of rows is '
        'built, not every item', (tester) async {
      setUpServiceWithLocalSource();
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );

      // Scan many photos, then mark every one permanently failed directly
      // in the mirror DB - the same end state a run of GallerySyncEngine
      // against a permanently-failing backend would leave, without the
      // engine/backend setup this view test does not need.
      const failureCount = 500;
      await mirror.applyLocalScan([
        for (var i = 0; i < failureCount; i++)
          localMediaItem(
            relativePath: 'DCIM/Camera/',
            displayName:
                'IMG_${i.toString().padLeft(4, '0')}.jpg',
            size: 1,
          ),
      ]);
      await (mirrorDb!.update(mirrorDb!.galleryItems)
            ..where((t) => t.uploadFailureBucket.isNull()))
          .write(const GalleryItemsCompanion(
        uploadFailureBucket: Value('permanent'),
        uploadFailureReason: Value('No space left on Seraph.'),
      ));

      // Register the controller the failure section reads from, with a
      // long poll interval so no periodic timer churns during the test.
      Get.put(GalleryDataSyncController(
        mirror,
        pollInterval: const Duration(minutes: 60),
      ));

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();

      // Bring the failure section into view - it lives below the folder
      // and Sync Pair sections.
      await tester.scrollUntilVisible(
        find.textContaining('Backup failed for $failureCount photos'),
        200,
        maxScrolls: 30,
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Backup failed for $failureCount photos'),
          findsOneWidget);

      // Virtualization: only a handful of Retry buttons are in the tree,
      // not 500. A non-virtualized Column would build every one and the
      // count would equal failureCount.
      final builtRetryButtons =
          find.widgetWithText(TextButton, 'Retry').evaluate().length;
      expect(builtRetryButtons, lessThan(50),
          reason: 'the failure list must be virtualized so thousands of '
              'items never build in a single frame; a Column would have '
              'built all $failureCount Retry buttons');

      // Dispose the controller (cancels its periodic poll timer) before the
      // test body ends - tearDown runs after the binding's pending-timer
      // check, so a live timer would fail the test.
      Get.delete<GalleryDataSyncController>();
    });
  });
}
