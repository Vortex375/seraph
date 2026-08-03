import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart' hide Value;
import 'package:oidc/oidc.dart';
import 'package:seraph_app/src/gallery/local/local_source.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_upload_backend.dart';
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

  // --- Ticket 17: incremental scan and the content-observer trigger ---

  /// What [currentGeneration] reports and, by default, what
  /// [incrementalScan] advances the watermark to - a test that wants to
  /// simulate "MediaStore's counter moved on" sets this directly.
  int generation = 0;

  /// What the next [incrementalScan] returns, regardless of `since` - a test
  /// drives this the same way it drives [setItems] for [fullScan]. Defaults
  /// to empty, matching a Local Source with nothing new to report.
  List<LocalMediaItem> incrementalItems = const [];

  /// Every `sinceGeneration` an [incrementalScan] call was made with, in
  /// order - what a test asserts against to verify the fast path only ever
  /// asked for what changed after the last watermark, never replayed the
  /// whole thing.
  final List<int> incrementalScanSinceCalls = [];
  int incrementalScanCount = 0;

  final StreamController<void> _changesController =
      StreamController<void>.broadcast();

  /// Simulates one content-observer notification - ticket 17's trigger only,
  /// carrying no information about what changed. A test drives bursts by
  /// calling this more than once in quick succession.
  ///
  /// A no-op once [dispose] has closed the underlying controller - mirrors
  /// `AndroidLocalSource` never delivering a native call that arrives after
  /// its own disposal (see [LocalSource.dispose]), so a test simulating a
  /// stray notification racing disposal does not hit a spurious "Cannot add
  /// new events after calling close" instead of exercising what it means to.
  void emitChange() {
    if (!_changesController.isClosed) {
      _changesController.add(null);
    }
  }

  @override
  Stream<void> get changes => _changesController.stream;

  /// How many times [dispose] has been called - what a test asserts against
  /// to check [LocalScanService.dispose] reaches the source at all, even
  /// though this fake (unlike `AndroidLocalSource`) has no method-channel
  /// handler to release.
  int disposeCount = 0;

  @override
  void dispose() {
    disposeCount++;
    if (!_changesController.isClosed) {
      unawaited(_changesController.close());
    }
  }

  @override
  Future<int> currentGeneration() async => generation;

  @override
  Future<LocalIncrementalScanResult> incrementalScan(
      int sinceGeneration) async {
    incrementalScanCount++;
    incrementalScanSinceCalls.add(sinceGeneration);
    return LocalIncrementalScanResult(
      items: incrementalItems,
      generation: generation,
    );
  }

  // --- Ticket 28: device photo previews ---

  /// What [loadThumbnail] returns for a given (relativePath, displayName) -
  /// unset (or returning null) is exactly the real contract's "cannot
  /// currently be read" case, so a test drives both the decode-failure and
  /// deleted-mid-render cases by simply leaving an identity out of this map,
  /// or removing one between two calls.
  final Map<String, Uint8List?> thumbnailBytes = {};

  /// Same idea as [thumbnailBytes], for [loadOriginal].
  final Map<String, Uint8List?> originalBytes = {};

  /// Every (relativePath, displayName, width, height) [loadThumbnail] was
  /// called with, in order - what a test asserts against to check a request
  /// was made at tile size rather than some other size.
  final List<(String, String, int, int)> thumbnailCalls = [];

  /// Every (relativePath, displayName) [loadOriginal] was called with.
  final List<(String, String)> originalCalls = [];

  static String _localKey(String relativePath, String displayName) =>
      '$relativePath\x00$displayName';

  /// Sets what [loadThumbnail] and [loadOriginal] return for one photo -
  /// the success case. A test simulating a photo that cannot be read simply
  /// never calls this for that identity, or calls [forgetLocalBytes]
  /// afterward to simulate it vanishing mid-render.
  void setLocalBytes(String relativePath, String displayName, Uint8List bytes) {
    final key = _localKey(relativePath, displayName);
    thumbnailBytes[key] = bytes;
    originalBytes[key] = bytes;
  }

  /// Simulates a photo deleted (or otherwise made unreadable) between the
  /// scan that found it and a later render: whatever [setLocalBytes] set
  /// for this identity is withdrawn, and the next [loadThumbnail]/
  /// [loadOriginal] call for it returns null exactly as the real
  /// [AndroidLocalSource] would for a vanished file.
  void forgetLocalBytes(String relativePath, String displayName) {
    final key = _localKey(relativePath, displayName);
    thumbnailBytes.remove(key);
    originalBytes.remove(key);
  }

  @override
  Future<Uint8List?> loadThumbnail({
    required String relativePath,
    required String displayName,
    required int width,
    required int height,
  }) async {
    thumbnailCalls.add((relativePath, displayName, width, height));
    return thumbnailBytes[_localKey(relativePath, displayName)];
  }

  @override
  Future<Uint8List?> loadOriginal({
    required String relativePath,
    required String displayName,
  }) async {
    originalCalls.add((relativePath, displayName));
    return originalBytes[_localKey(relativePath, displayName)];
  }
}

/// Ticket 19's "covered at the app's mirror seam with a stubbed backend" -
/// an in-memory stand-in for [GalleryUploadBackend], driven entirely by the
/// test, so [GalleryUploadService](../../lib/src/gallery/mirror/gallery_upload_service.dart)'s
/// never-overwrite/disambiguation/mark-synced logic can be exercised without
/// a real WebDAV server or `webdav_client`'s own Dio adapter plumbing.
class FakeGalleryUploadBackend implements GalleryUploadBackend {
  final Map<String, Uint8List> _remote = {};

  /// Every (spaceProviderId, path, bytes) [put] was called with, in order -
  /// what a test asserts against to check exactly one PUT happened (ticket
  /// 19's "no client-side staging" criterion - one write, straight to the
  /// final path, never a staging name followed by a move) and that it
  /// carried exactly the bytes the fake Local Source reported (the
  /// byte-identical criterion).
  final List<(String, String, Uint8List)> putCalls = [];

  /// Every (spaceProviderId, path) [statSize] was asked about, in order -
  /// what a test asserts against to check the never-overwrite/disambiguation
  /// loop walked exactly the candidate names it should have, and no more.
  final List<(String, String)> statCalls = [];

  /// When set, the next [statSize] call throws this instead of consulting
  /// [_remote] - simulates a failure (a read-only Space, in particular)
  /// discovered on the existence check itself, before any PUT is attempted.
  GalleryUploadException? statError;

  /// When set, the next [put] call throws this instead of writing to
  /// [_remote] - simulates a connection lost mid-upload, or a failure only
  /// discovered on the write. Because the fake never writes to [_remote]
  /// before throwing, this is also what stands in for server-side atomic PUT
  /// (ADR 0002's amendment): a failed [put] leaves nothing at the target
  /// path, exactly as the ticket's "leaves no partial file" criterion
  /// requires.
  GalleryUploadException? putError;

  /// Every (spaceProviderId, path) [remove] was called with, in order - what
  /// ticket 20's mismatch-retry tests assert against to check the untrusted
  /// remote file was actually deleted before the retry PUT.
  final List<(String, String)> removeCalls = [];

  /// When set, the next [remove] call throws this instead of deleting from
  /// [_remote].
  GalleryUploadException? removeError;

  static String _key(String spaceProviderId, String path) =>
      '$spaceProviderId\x00$path';

  /// Seeds [_remote] as though [bytes] already occupied (spaceProviderId,
  /// path) before any upload runs - a test's way of setting up a collision,
  /// same-size or different-size.
  void seed(String spaceProviderId, String path, Uint8List bytes) {
    _remote[_key(spaceProviderId, path)] = bytes;
  }

  /// What currently sits at (spaceProviderId, path) in the fake, or null -
  /// read back to confirm an upload actually happened (or didn't), and that
  /// a disambiguated upload left the original path's content untouched.
  Uint8List? contentAt(String spaceProviderId, String path) =>
      _remote[_key(spaceProviderId, path)];

  @override
  Future<int?> statSize(String spaceProviderId, String path) async {
    statCalls.add((spaceProviderId, path));
    final error = statError;
    if (error != null) {
      throw error;
    }
    return _remote[_key(spaceProviderId, path)]?.length;
  }

  @override
  Future<void> put(
      String spaceProviderId, String path, Uint8List bytes) async {
    putCalls.add((spaceProviderId, path, bytes));
    final error = putError;
    if (error != null) {
      throw error;
    }
    _remote[_key(spaceProviderId, path)] = bytes;
  }

  @override
  Future<void> remove(String spaceProviderId, String path) async {
    removeCalls.add((spaceProviderId, path));
    final error = removeError;
    if (error != null) {
      throw error;
    }
    _remote.remove(_key(spaceProviderId, path));
  }
}

/// Ticket 30's mirror-seam clock fake: a settable "now" for
/// [GalleryGridController]'s sync throttle and full-scan backstop, so a test
/// can assert on both without actually waiting out a 60-second throttle or a
/// 6-hour backstop. Pass [call] itself as `GalleryGridController(now: ...)`'s
/// clock; advance time between calls with [advance] or by setting [current]
/// directly.
class FakeClock {
  FakeClock([DateTime? start]) : current = start ?? DateTime(2026);

  DateTime current;

  /// Moves the clock forward by [duration] - the usual way a test simulates
  /// "some time passed" between two sync calls without a real delay.
  void advance(Duration duration) => current = current.add(duration);

  DateTime call() => current;
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
