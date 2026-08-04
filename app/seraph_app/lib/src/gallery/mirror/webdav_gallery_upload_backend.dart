import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_upload_backend.dart';

/// The production [GalleryUploadBackend], over the same [FileService]
/// (and therefore the same WebDAV [Client](package:webdav_client/webdav_client.dart))
/// the file browser already uses - one WebDAV client in the app, not a
/// second one built for Gallery Mode.
///
/// Lives in this separate file (rather than alongside the abstract
/// [GalleryUploadBackend] in `gallery_upload_backend.dart`) so that the
/// headless sync engine's import graph stays Flutter-free and GetX-free:
/// [FileService] transitively pulls in `LoginController`/`ShareController`
/// (real GetxControllers importing `package:flutter/material.dart`), and
/// the engine - which runs in a background isolate after the UI isolate is
/// killed - must not reach any of that. The isolate entrypoint
/// (`../sync/gallery_headless_sync.dart`) uses its own
/// [HeadlessWebDavBackend] over a raw `webdav_client` [Client] instead;
/// only the UI wiring (`initial_binding.dart`) instantiates THIS class.
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

  @override
  Future<void> remove(String spaceProviderId, String path) async {
    try {
      await fileService.removeFile(_webDavPath(spaceProviderId, path));
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      if (status == 404) {
        // Already gone - not an error (see this method's doc on the
        // interface).
        return;
      }
      throw _translate(e, status);
    } on StateError catch (e) {
      throw GalleryUploadException(e.message);
    }
  }

  GalleryUploadException _translate(DioException e, int? status) =>
      translateWebDavError(e, status);
}
