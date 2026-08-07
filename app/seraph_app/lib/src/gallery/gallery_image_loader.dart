import 'dart:async';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:seraph_app/src/gallery/gallery_media.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/util.dart';

/// Thrown when a gallery image could not be produced: neither the cache nor
/// the network had it. Carries [cause] so a failure while offline is
/// distinguishable from a 404 in logs.
class GalleryImageUnavailable implements Exception {
  GalleryImageUnavailable(this.location, this.cause);

  final String location;
  final Object cause;

  @override
  String toString() => 'GalleryImageUnavailable($location): $cause';
}

/// Fetches gallery pixels over the existing authenticated HTTP path, and
/// keeps thumbnail bytes in the mirror database.
///
/// Why the cache exists: "with no network, the gallery still opens and shows
/// already-cached Thumbnails". Opening is the mirror's doing; the thumbnails
/// are this class's. The cache is consulted first and the network only on a
/// miss, so a thumbnail seen once keeps rendering with the network gone; only
/// a photo never scrolled past before goes dark.
///
/// Full-resolution images are deliberately NOT cached: they are large, they
/// are viewed one at a time, and caching them would evict thousands of
/// thumbnails to spare one photo a re-fetch.
class GalleryImageLoader {
  GalleryImageLoader(
    this.settingsController,
    this.loginController,
    this.db, {
    Dio? dio,
    this.maxCachedThumbnails = 2000,
  }) : dio = dio ?? Dio();

  final SettingsController settingsController;
  final LoginController loginController;
  final GalleryMirrorDatabase db;
  final Dio dio;

  /// How many thumbnails the cache keeps before evicting oldest-first. At the
  /// warmed size (512 px, roughly 40 KB) this is a few tens of megabytes -
  /// enough for a deep scroll back through a collection, bounded enough for
  /// the browser's storage quota on the web build.
  final int maxCachedThumbnails;

  /// In-flight requests, keyed like the cache, so a grid that builds the same
  /// tile twice in one frame (or a tile that scrolls out and back) issues one
  /// request rather than two.
  final Map<String, Future<Uint8List>> _inFlight = {};

  int _writesSinceEviction = 0;

  GalleryMediaUrls get _urls => GalleryMediaUrls(settingsController.serverUrl.value);

  /// Bytes of the thumbnail of [providerId]/[path] at [size], from the cache
  /// if present and from the preview endpoint otherwise.
  Future<Uint8List> thumbnail(String providerId, String path, int size) {
    final key = '$size\x00$providerId\x00$path';
    final existing = _inFlight[key];
    if (existing != null) {
      return existing;
    }
    // The callback must not RETURN the removed entry: whenComplete waits on a
    // returned future, and the removed entry is this very future - which
    // would deadlock every first fetch of every thumbnail.
    final future = _thumbnail(providerId, path, size).whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  Future<Uint8List> _thumbnail(String providerId, String path, int size) async {
    final cached = await _readCache(providerId, path, size);
    if (cached != null) {
      return cached;
    }

    final Uint8List bytes;
    try {
      bytes = await _get(_urls.thumbnail(providerId, path, size));
    } catch (e) {
      throw GalleryImageUnavailable('$providerId$path', e);
    }

    await _writeCache(providerId, path, size, bytes);
    return bytes;
  }

  /// Bytes of the original file, at full resolution. Not cached.
  Future<Uint8List> fullResolution(String providerId, String path) async {
    try {
      return await _get(_urls.fullResolution(providerId, path));
    } catch (e) {
      throw GalleryImageUnavailable('$providerId$path', e);
    }
  }

  Future<Uint8List> _get(String url) {
    Future<Uint8List> request() async {
      final response = await dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: await _requestHeaders(),
        ),
      );
      return Uint8List.fromList(response.data ?? const []);
    }

    return _withTokenRecovery(request);
  }

  /// Reactive refresh-and-retry for the gallery's thumbnail and full-resolution
  /// image fetches - the safety net the proactive refresh triggers (cold
  /// start, resume, 30s audio timer) cannot guarantee covers this path.
  ///
  /// The gateway answers an expired access token with HTTP 403 (the SAME
  /// status a genuinely read-only Space produces), and [LoginController]'s
  /// proactive triggers do not cover a user browsing the gallery in the
  /// foreground past the access-token's lifetime (5 minutes, for the test
  /// realm) with no resume and no audio playing. Without this, every
  /// non-cached thumbnail fetched after expiry 403s, [GalleryImage._load]
  /// throws [GalleryImageUnavailable], and the tile renders its error
  /// placeholder - until some other path (switching to the file browser, whose
  /// WebDAV calls DO recover via [FileService._withTokenRecovery]) refreshes
  /// the token. This catches it here instead: on a 401/403 [DioException],
  /// force-refreshes the token and retries [op] once. The retry re-reads the
  /// bearer via [_requestHeaders] (which reads [loginController.currentUser],
  /// set synchronously by the forced [LoginController.refreshTokenIfNeeded]);
  /// a second failure of any kind propagates as-is, becoming
  /// [GalleryImageUnavailable] the same way a 404 or a network error already
  /// does. Mirrors [FileService._withTokenRecovery] and
  /// [withTokenRecovery] (gallery_upload_backend.dart) exactly.
  Future<T> _withTokenRecovery<T>(Future<T> Function() op) async {
    try {
      return await op();
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 401 || status == 403) {
        await loginController.refreshTokenIfNeeded(force: true);
        return await op();
      }
      rethrow;
    }
  }

  Future<Map<String, String>> _requestHeaders() async {
    await until(loginController.isInitialized, identity);

    final user = loginController.currentUser.value;
    if (user != null) {
      return {'Authorization': 'Bearer ${user.token.accessToken}'};
    }
    return {};
  }

  Future<Uint8List?> _readCache(String providerId, String path, int size) async {
    final row = await (db.select(db.cachedThumbnails)
          ..where((t) =>
              t.providerId.equals(providerId) &
              t.path.equals(path) &
              t.size.equals(size)))
        .getSingleOrNull();
    return row?.bytes;
  }

  Future<void> _writeCache(
      String providerId, String path, int size, Uint8List bytes) async {
    if (bytes.isEmpty) {
      return;
    }
    await db.into(db.cachedThumbnails).insertOnConflictUpdate(
          CachedThumbnailsCompanion.insert(
            providerId: providerId,
            path: path,
            size: size,
            bytes: bytes,
            fetchedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );

    // Counting rows on every write would put a COUNT(*) in the path of every
    // tile that scrolls into view; checking periodically bounds the cache
    // just as well, a few entries late.
    _writesSinceEviction++;
    if (_writesSinceEviction >= 50) {
      _writesSinceEviction = 0;
      await evictOverflow();
    }
  }

  /// Drops the oldest cached thumbnails until at most [maxCachedThumbnails]
  /// remain. Public so a test can drive it directly rather than by writing
  /// fifty entries.
  Future<void> evictOverflow() async {
    final countExp = db.cachedThumbnails.providerId.count();
    final countRow =
        await (db.selectOnly(db.cachedThumbnails)..addColumns([countExp]))
            .getSingle();
    final total = countRow.read(countExp) ?? 0;
    final overflow = total - maxCachedThumbnails;
    if (overflow <= 0) {
      return;
    }

    final victims = await (db.select(db.cachedThumbnails)
          ..orderBy([(t) => OrderingTerm(expression: t.fetchedAt)])
          ..limit(overflow))
        .get();

    for (final victim in victims) {
      await (db.delete(db.cachedThumbnails)
            ..where((t) =>
                t.providerId.equals(victim.providerId) &
                t.path.equals(victim.path) &
                t.size.equals(victim.size)))
          .go();
    }
  }
}

/// An [ImageProvider] over [GalleryImageLoader], so gallery tiles get
/// Flutter's usual decoded-image cache and de-duplication - two tiles showing
/// the same photo decode it once - which a `FutureBuilder` around
/// `Image.memory` would not.
@immutable
class GalleryImage extends ImageProvider<GalleryImage> {
  const GalleryImage({
    required this.loader,
    required this.providerId,
    required this.path,
    this.size,
  });

  final GalleryImageLoader loader;
  final String providerId;
  final String path;

  /// Requested thumbnail size, or null for the original file at full
  /// resolution.
  final int? size;

  @override
  Future<GalleryImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<GalleryImage>(this);

  @override
  ImageStreamCompleter loadImage(
      GalleryImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: 1.0,
      debugLabel: 'GalleryImage(${key.providerId}${key.path}, ${key.size})',
    );
  }

  Future<ui.Codec> _load(GalleryImage key, ImageDecoderCallback decode) async {
    final bytes = key.size == null
        ? await key.loader.fullResolution(key.providerId, key.path)
        : await key.loader.thumbnail(key.providerId, key.path, key.size!);

    if (bytes.isEmpty) {
      throw GalleryImageUnavailable(
          '${key.providerId}${key.path}', 'empty response');
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is GalleryImage &&
      other.providerId == providerId &&
      other.path == path &&
      other.size == size;

  @override
  int get hashCode => Object.hash(providerId, path, size);
}
