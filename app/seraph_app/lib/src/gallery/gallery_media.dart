/// Where Gallery Mode gets its pixels from.
///
/// Both endpoints already exist and are used by the file browser and file
/// viewer; Gallery Mode introduces no media-serving endpoint of its own. The
/// gallery API hands back SPACE coordinates - (providerId, path) - precisely
/// so that they can be fed straight into these (see `GalleryListItem`'s doc
/// in `gallery/gallery/messages.go`).
///
/// - Thumbnails: `GET /preview?p=<providerId><path>&w=&h=`, the same endpoint
///   `FileService.getPreviewUrl` uses. It serves thumbnails the thumbnailer
///   generated with `imaging.AutoOrientation(true)`, so they arrive already
///   rotated.
/// - Full resolution: `GET /dav/p/<providerId><path>`, the WebDAV read path
///   `FileService.getFileUrl` uses for the file viewer's full-size images.
///   (`/download/...` is the *archive* endpoint - it returns a zip - so it is
///   not what "download the image" means here.)
library;

/// Builds the media URLs for one Seraph server.
class GalleryMediaUrls {
  const GalleryMediaUrls(this.serverUrl);

  /// The base URL of the Seraph server, e.g. `https://seraph.example`.
  final String serverUrl;

  /// URL of a thumbnail of at most [size] x [size] pixels.
  ///
  /// The thumbnailer snaps the requested size up to its own ladder, so this
  /// is a request, not a promise about the returned pixel size.
  String thumbnail(String providerId, String path, int size) {
    final p = Uri.encodeQueryComponent(_spaceLocation(providerId, path));
    return '${_base()}/preview?p=$p&w=$size&h=$size';
  }

  /// URL of the original file, at full resolution.
  String fullResolution(String providerId, String path) {
    final encoded = _spaceLocation(providerId, path)
        .split('/')
        .map(Uri.encodeComponent)
        .join('/');
    return '${_base()}/dav/p$encoded';
  }

  String _base() =>
      serverUrl.endsWith('/')
          ? serverUrl.substring(0, serverUrl.length - 1)
          : serverUrl;
}

/// `/<providerId><path>` - the single string both endpoints take as a
/// location, with [path] already starting with `/` as the gallery API returns
/// it. Tolerant of a path that does not, so a hand-built call is not a
/// silent 400.
String _spaceLocation(String providerId, String path) {
  if (path.isEmpty) {
    return '/$providerId';
  }
  return path.startsWith('/') ? '/$providerId$path' : '/$providerId/$path';
}
