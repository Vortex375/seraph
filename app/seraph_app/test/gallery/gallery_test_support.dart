import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart' hide Value;
import 'package:oidc/oidc.dart';
import 'package:seraph_app/src/gallery/local/local_source.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/share/share_controller.dart';

/// A [LocalSource] driven entirely by the test - what ticket 15's mirror-seam
/// coverage requirement ("a fake Local Source") asks for. [items] can be
/// reassigned between scans, so a test can simulate a device photo appearing
/// or disappearing across two calls to [LocalScanService.scan]
/// (`local_scan_service.dart`).
///
/// [permissionStatus] can likewise be reassigned between reads, so a ticket
/// 16 test can drive the same fake through granted, partial and denied
/// without standing up three separate sources - see [setPermissionStatus].
class FakeLocalSource implements LocalSource {
  FakeLocalSource([
    List<LocalMediaItem> items = const [],
    LocalPermissionStatus permissionStatus = LocalPermissionStatus.granted,
  ])  : _items = items,
        _permissionStatus = permissionStatus;

  List<LocalMediaItem> _items;
  LocalPermissionStatus _permissionStatus;
  int scanCount = 0;
  int requestCount = 0;
  int openSettingsCount = 0;

  /// What the next [requestPermission] resolves to. Defaults to whatever
  /// [setPermissionStatus] last set, mirroring the real
  /// `AndroidLocalSource`: asking again reports the grant the platform now
  /// holds. A test can override this independently (e.g. "still partial
  /// after the user adds one more photo") by setting it after
  /// [setPermissionStatus].
  LocalPermissionStatus? nextRequestResult;

  /// Replaces what the next [fullScan] returns.
  void setItems(List<LocalMediaItem> items) => _items = items;

  /// Replaces what [permissionStatus] and, unless overridden by
  /// [nextRequestResult], [requestPermission] report.
  void setPermissionStatus(LocalPermissionStatus status) =>
      _permissionStatus = status;

  @override
  Future<List<LocalMediaItem>> fullScan() async {
    scanCount++;
    return _items;
  }

  @override
  Future<LocalPermissionStatus> permissionStatus() async => _permissionStatus;

  @override
  Future<LocalPermissionStatus> requestPermission() async {
    requestCount++;
    _permissionStatus = nextRequestResult ?? _permissionStatus;
    return _permissionStatus;
  }

  @override
  Future<void> openAppSettings() async {
    openSettingsCount++;
  }
}

/// A [LocalMediaItem] with sensible defaults, for tests that only care about
/// a couple of fields.
LocalMediaItem localMediaItem({
  String relativePath = 'DCIM/Camera/',
  String displayName = 'IMG_0001.jpg',
  int size = 1024,
  int dateTakenMillis = 1000000,
  int? dateModifiedMillis,
  int? mediaStoreId,
}) {
  return LocalMediaItem(
    relativePath: relativePath,
    displayName: displayName,
    size: size,
    dateTakenMillis: dateTakenMillis,
    dateModifiedMillis: dateModifiedMillis ?? dateTakenMillis,
    mediaStoreId: mediaStoreId,
  );
}

/// A 1x1 PNG - enough for a widget test to have real, decodable bytes coming
/// back from the stubbed preview endpoint.
final Uint8List onePixelPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

/// A 40x20 JPEG carrying EXIF Orientation 6 (rotate 90 clockwise), so that
/// displayed it is 20x40. Used to pin down whether the decoder applies the
/// orientation tag itself - which decides whether the app has to.
final Uint8List exifOrientation6Jpeg = base64Decode(
    '/9j/4AAQSkZJRgABAQAAAQABAAD/4QAiRXhpZgAATU0AKgAAAAgAAQESAAMAAAABAAYA'
    'AAAAAAD/2wBDAA0JCgsKCA0LCgsODg0PEyAVExISEyccHhcgLikxMC4pLSwzOko+MzZG'
    'NywtQFdBRkxOUlNSMj5aYVpQYEpRUk//2wBDAQ4ODhMREyYVFSZPNS01T09PT09PT09P'
    'T09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT09PT0//wAARCAAUACgD'
    'ASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgED'
    'AwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkK'
    'FhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqD'
    'hIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ'
    '2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcI'
    'CQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHB'
    'CSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVm'
    'Z2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPE'
    'xcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDCooor'
    'zj7EKKKKACiiigAooooAKKKKACiiigD/2Q==');

/// An empty in-memory mirror.
GalleryMirrorDatabase openTestMirrorDatabase() =>
    GalleryMirrorDatabase(NativeDatabase.memory());

/// Writes one gallery item straight into the mirror.
///
/// Tests that are about the gallery view pre-populate the mirror this way
/// rather than by driving the delta feed: how rows get there is ticket 12's
/// question and is covered by its own tests, and going through the feed here
/// would only make these tests slower and less direct.
Future<void> insertMirrorItem(
  GalleryMirrorDatabase db, {
  String providerId = 'space-a',
  required String path,
  required int capturedAt,
  String capturedAtSource = 'exif',
  int width = 4000,
  int height = 3000,
  int orientation = 1,
  int size = 1024,
  String mime = 'image/jpeg',
  String unsupported = '',
  bool metadataPending = false,
}) async {
  await db.into(db.galleryItems).insertOnConflictUpdate(
        GalleryItemsCompanion.insert(
          providerId: Value(providerId),
          path: Value(path),
          capturedAt: capturedAt,
          capturedAtSource: Value(capturedAtSource),
          width: Value(width),
          height: Value(height),
          orientation: Value(orientation),
          size: Value(size),
          mime: Value(mime),
          unsupported: Value(unsupported),
          metadataPending: Value(metadataPending),
        ),
      );
}

/// Fills the mirror with [count] items, one per day going back from
/// [newestCapturedAt] (epoch seconds), newest first.
Future<void> populateMirror(
  GalleryMirrorDatabase db, {
  required int count,
  int newestCapturedAt = 1770000000,
  String providerId = 'space-a',
}) async {
  const secondsPerDay = 24 * 60 * 60;
  for (var i = 0; i < count; i++) {
    await insertMirrorItem(
      db,
      providerId: providerId,
      path: '/Photos/photo-$i.jpg',
      capturedAt: newestCapturedAt - i * secondsPerDay,
    );
  }
}

/// Reads back the mirror's own ordering, for tests that want to assert
/// against the same order the grid will show.
Future<List<GalleryItem>> mirrorInOrder(GalleryMirror mirror) =>
    mirror.queryItems(offset: 0, limit: 10000);

class FakeSettingsController extends GetxController
    implements SettingsController {
  FakeSettingsController([String url = 'https://seraph.test'])
      : _serverUrl = url.obs;

  final Rx<String> _serverUrl;
  final Rx<bool> _serverUrlConfirmed = true.obs;
  final Rx<String?> _oidcIssuer = Rx<String?>(null);
  final Rx<String?> _oidcClientId = Rx<String?>(null);
  final Rx<ThemeMode> _themeMode = Rx<ThemeMode>(ThemeMode.light);
  final Rx<String> _fileBrowserViewMode = 'list'.obs;

  @override
  Rx<String> get serverUrl => _serverUrl;

  @override
  Rx<bool> get serverUrlConfirmed => _serverUrlConfirmed;

  @override
  Rx<String?> get oidcIssuer => _oidcIssuer;

  @override
  Rx<String?> get oidcClientId => _oidcClientId;

  @override
  Rx<ThemeMode> get themeMode => _themeMode;

  @override
  Rx<String> get fileBrowserViewMode => _fileBrowserViewMode;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeLoginController extends GetxController implements LoginController {
  final Rx<bool> _isInitialized = true.obs;
  final Rx<bool> _isNoAuth = false.obs;
  final Rx<bool> _isSpaceAdmin = false.obs;
  final Rx<OidcUser?> _currentUser = Rx<OidcUser?>(null);

  @override
  Rx<bool> get isInitialized => _isInitialized;

  @override
  Rx<bool> get isNoAuth => _isNoAuth;

  @override
  Rx<bool> get isSpaceAdmin => _isSpaceAdmin;

  @override
  Rx<OidcUser?> get currentUser => _currentUser;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeShareController extends GetxController implements ShareController {
  @override
  final RxBool shareMode = false.obs;

  @override
  final RxBool fail = false.obs;

  @override
  final RxBool ready = true.obs;

  @override
  final Rx<String?> title = Rx<String?>(null);

  @override
  final RxBool isDir = false.obs;

  @override
  final RxMap<String, String> sharedPaths = <String, String>{}.obs;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
