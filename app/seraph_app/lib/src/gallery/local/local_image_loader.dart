import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:seraph_app/src/gallery/local/local_source.dart';

/// Thrown when a device photo's pixels could not be produced: no Local
/// Source, the file could not currently be read, or a decode failure.
/// [LocalGalleryImage] throws this from an empty/null response so a plain
/// `Image.errorBuilder` is what turns it into ticket 28's "failure is
/// per-item and quiet" - a placeholder for that one tile, or (for a Synced
/// item) a fall back to the cloud thumbnail, never a crash or a blank grid.
class LocalGalleryImageUnavailable implements Exception {
  LocalGalleryImageUnavailable(this.location);

  final String location;

  @override
  String toString() => 'LocalGalleryImageUnavailable($location)';
}

/// Loads device-photo pixel bytes through the Local Source seam (ticket 28,
/// `.scratch/gallery-mode/issues/28-device-photo-previews.md`) - the
/// preview-loading twin of `GalleryImageLoader`, which does the same job for
/// cloud photos over HTTP.
///
/// Unlike `GalleryImageLoader`, nothing here is cached to disk: the bytes
/// already live on the device, so there is no network round trip to spare a
/// second fetch, and re-asking the Local Source for the same tile costs
/// only what `ContentResolver.loadThumbnail` costs on the Android side -
/// which itself already consults the system's own thumbnail cache. Only
/// in-flight de-duplication lives here, exactly as `GalleryImageLoader`
/// does for its own cache misses, so a tile that builds twice in one frame
/// (or scrolls out and back while its request is still in flight) issues
/// one native call rather than two. Flutter's own `ImageCache` - the same
/// mechanism every `Image` widget already relies on - is what bounds memory
/// and evicts decoded frames for tiles scrolled off screen; nothing here
/// duplicates that.
class LocalImageLoader {
  LocalImageLoader(this.localSource);

  /// Null on every platform without a Local Source - iOS, desktop, web, or
  /// any test with nothing to do with device photos. [thumbnail] and
  /// [original] are then simply unable to produce bytes, exactly the same
  /// "no Local Source, nothing to show" shape [LocalSource] itself uses
  /// throughout, so callers never have to branch on null separately from
  /// any other failure.
  final LocalSource? localSource;

  /// In-flight requests, keyed like `GalleryImageLoader`'s own cache: a
  /// request for the same photo at the same size that arrives while one is
  /// already running gets the same future rather than a second native call.
  final Map<String, Future<Uint8List?>> _inFlight = {};

  /// Bytes for a tile-sized thumbnail of the photo identified by
  /// [relativePath]/[displayName], close to [width]x[height] - see
  /// [LocalSource.loadThumbnail]. Null when the photo cannot currently be
  /// produced; never throws.
  Future<Uint8List?> thumbnail(
    String relativePath,
    String displayName,
    int width,
    int height,
  ) {
    final key = 'thumb\x00$width\x00$height\x00$relativePath\x00$displayName';
    return _dedup(key, () {
      final source = localSource;
      if (source == null) {
        return Future.value(null);
      }
      return source.loadThumbnail(
        relativePath: relativePath,
        displayName: displayName,
        width: width,
        height: height,
      );
    });
  }

  /// Bytes for the original file, at full resolution - see
  /// [LocalSource.loadOriginal]. Null when the photo cannot currently be
  /// produced; never throws.
  Future<Uint8List?> original(String relativePath, String displayName) {
    final key = 'orig\x00$relativePath\x00$displayName';
    return _dedup(key, () {
      final source = localSource;
      if (source == null) {
        return Future.value(null);
      }
      return source.loadOriginal(
          relativePath: relativePath, displayName: displayName);
    });
  }

  Future<Uint8List?> _dedup(
      String key, Future<Uint8List?> Function() request) {
    final existing = _inFlight[key];
    if (existing != null) {
      return existing;
    }
    // As with GalleryImageLoader's own _inFlight map, the callback must not
    // RETURN the removed entry - whenComplete waits on a returned future,
    // and the removed entry is this very future.
    final future = request().whenComplete(() {
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }
}

/// An [ImageProvider] over [LocalImageLoader], so a device photo gets
/// Flutter's usual decoded-image cache and de-duplication - the same
/// benefit `GalleryImage` gives cloud photos.
@immutable
class LocalGalleryImage extends ImageProvider<LocalGalleryImage> {
  const LocalGalleryImage({
    required this.loader,
    required this.relativePath,
    required this.displayName,
    this.width,
    this.height,
  });

  final LocalImageLoader loader;
  final String relativePath;
  final String displayName;

  /// Requested thumbnail size in pixels - both null requests the original
  /// at full resolution. Always given as a pair: a thumbnail request with
  /// only one of the two would not describe a size
  /// [LocalSource.loadThumbnail] can act on.
  final int? width;
  final int? height;

  @override
  Future<LocalGalleryImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<LocalGalleryImage>(this);

  @override
  ImageStreamCompleter loadImage(
      LocalGalleryImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: 1.0,
      debugLabel:
          'LocalGalleryImage(${key.relativePath}${key.displayName}, '
          '${key.width}x${key.height})',
    );
  }

  Future<ui.Codec> _load(
      LocalGalleryImage key, ImageDecoderCallback decode) async {
    final w = key.width;
    final h = key.height;
    final bytes = (w == null || h == null)
        ? await key.loader.original(key.relativePath, key.displayName)
        : await key.loader.thumbnail(key.relativePath, key.displayName, w, h);

    if (bytes == null || bytes.isEmpty) {
      throw LocalGalleryImageUnavailable('${key.relativePath}${key.displayName}');
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is LocalGalleryImage &&
      other.relativePath == relativePath &&
      other.displayName == displayName &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(relativePath, displayName, width, height);
}
