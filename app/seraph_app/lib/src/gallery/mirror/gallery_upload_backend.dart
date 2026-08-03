import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';

/// Thrown by a [GalleryUploadBackend] when a remote operation fails for a
/// reason [GalleryUploadService](gallery_upload_service.dart) cannot itself
/// recover from - a read-only Space (ticket 19's "fails with a comprehensible
/// reason rather than silently" criterion) chief among them.
///
/// Deliberately not a [DioException] subclass or wrapper: the whole point of
/// [GalleryUploadBackend] is that nothing above it needs to know the remote
/// side is WebDAV at all, HTTP-flavoured errors included - a test's fake
/// backend throws this directly, with no HTTP response to fabricate.
class GalleryUploadException implements Exception {
  const GalleryUploadException(this.message, {this.readOnly = false});

  /// A message fit to show the user directly - see [WebDavGalleryUploadBackend]
  /// for the wording used for each server response this seam recognises.
  final String message;

  /// True when the failure was specifically "this Space will not accept a
  /// write" (WebDAV 403) - callers do not currently branch on this, but a
  /// future failure-list UI (ticket 25) is expected to want the distinction
  /// between "read-only Space" and "everything else" without re-parsing
  /// [message].
  final bool readOnly;

  @override
  String toString() => message;
}

/// What ticket 19's upload needs from the remote filesystem: whether
/// something already occupies a target path, and how to publish new content
/// there. Narrow on purpose - see the class doc on
/// [GalleryUploadService](gallery_upload_service.dart) for why upload logic
/// (the never-overwrite rule, disambiguation, marking an item Synced) is kept
/// entirely out of this interface and lives one layer up instead: this seam
/// exists solely so that logic can be tested with an in-memory fake, per the
/// ticket's "covered at the app's mirror seam with a stubbed backend"
/// criterion, without standing up a real WebDAV server or fighting
/// `webdav_client`'s own Dio adapter plumbing.
abstract class GalleryUploadBackend {
  /// The size in bytes of whatever currently occupies ([spaceProviderId],
  /// [path]), or null if nothing is there yet.
  ///
  /// Throws [GalleryUploadException] for anything other than "found" or "not
  /// found" - a read-only Space in particular, which a stat can already
  /// reveal without ever attempting the PUT.
  Future<int?> statSize(String spaceProviderId, String path);

  /// Publishes [bytes] at ([spaceProviderId], [path]), creating any missing
  /// intermediate folders. Callers only ever call this once [statSize] has
  /// reported the target empty - see [GalleryUploadService.upload] - so an
  /// implementation is never asked to overwrite anything itself; the
  /// never-overwrite rule lives one layer up, not here.
  ///
  /// Throws [GalleryUploadException] on failure - a read-only Space, the
  /// server out of storage, or a dropped connection alike. An upload that
  /// throws must leave nothing at [path]: server-side atomic PUT (ADR 0002's
  /// amendment) is what makes that true for [WebDavGalleryUploadBackend]
  /// without any client-side staging of its own.
  Future<void> put(String spaceProviderId, String path, Uint8List bytes);
}

/// The production [GalleryUploadBackend], over the same [FileService]
/// (and therefore the same WebDAV [Client](package:webdav_client/webdav_client.dart))
/// the file browser already uses - one WebDAV client in the app, not a
/// second one built for Gallery Mode.
class WebDavGalleryUploadBackend implements GalleryUploadBackend {
  WebDavGalleryUploadBackend(this.fileService);

  final FileService fileService;

  /// [spaceProviderId]/[path] in Space terms (as [GallerySourceFolder] and
  /// every Sync Pair store them) translated to the flat WebDAV path
  /// [FileService] takes - the same `/<spaceProviderId><path>` shape
  /// [GalleryItemDisplay.spaceDisplayPath] already computes for the preview
  /// and download endpoints (`gallery_item_display.dart`), spelled out again
  /// here rather than imported so this file has no dependency on the mirror's
  /// presentation layer.
  String _webDavPath(String spaceProviderId, String path) {
    final rel = path.startsWith('/') ? path : '/$path';
    return '/$spaceProviderId$rel';
  }

  @override
  Future<int?> statSize(String spaceProviderId, String path) async {
    try {
      final file = await fileService.stat(_webDavPath(spaceProviderId, path));
      if (file == null) {
        // [FileService.stat] returns null only when no server is configured
        // at all (see its own doc) - every real "not found" response throws,
        // caught below. Treating this as "not connected" rather than "path
        // free" matters: the latter would let an upload proceed with no
        // server to receive it.
        throw const GalleryUploadException('Not connected to Seraph.');
      }
      return file.size;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 404) {
        return null;
      }
      throw _translate(e, status);
    }
  }

  @override
  Future<void> put(String spaceProviderId, String path, Uint8List bytes) async {
    try {
      await fileService.writeBytes(_webDavPath(spaceProviderId, path), bytes);
    } on DioException catch (e) {
      throw _translate(e, e.response?.statusCode);
    } on StateError catch (e) {
      // [FileService.writeBytes] throws this when no server is configured at
      // all - the same "not connected" case [statSize] recognises via a null
      // [FileService.stat] result.
      throw GalleryUploadException(e.message);
    }
  }

  GalleryUploadException _translate(DioException e, int? status) {
    if (status == 403) {
      return const GalleryUploadException(
        'This Space is read-only - uploading is not allowed here.',
        readOnly: true,
      );
    }
    if (status == 507) {
      return const GalleryUploadException('Seraph is out of storage space.');
    }
    return GalleryUploadException(
        'Could not reach Seraph (${status ?? e.message}).');
  }
}
