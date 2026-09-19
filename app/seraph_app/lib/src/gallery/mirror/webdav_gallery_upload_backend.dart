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
///
/// Every WebDAV operation is wrapped in [withTokenRecovery]: a 401/403 from
/// the gateway (the auth middleware's response to an expired access token -
/// see [tokenRecoveryStatuses]'s own doc for why that is the SAME status a
/// genuinely read-only Space produces) triggers one forced refresh via
/// [LoginController.refreshTokenIfNeeded] and a single retry. [FileService]
/// reads the bearer from [LoginController.currentUser] before every
/// request (`getRequestHeaders` → `setHeaders`), so the retry automatically
/// uses the just-refreshed access token - this is the reactive safety net
/// the proactive (resume / audio-timer) refresh triggers alone cannot
/// guarantee covers the access token's short lifetime.
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

  /// The refresh callback [withTokenRecovery] calls between the failed
  /// attempt and its retry. For the UI-isolate backend this is a forced
  /// refresh on the same [LoginController] [FileService] already reads the
  /// bearer from, so the retry's `setHeaders` picks up the fresh access
  /// token automatically - no header plumbing of its own here.
  Future<void> _refreshToken() =>
      fileService.loginController.refreshTokenIfNeeded(force: true);

  @override
  Future<int?> statSize(String spaceProviderId, String path) async {
    try {
      return await withTokenRecovery<int?>(
        op: () async {
          try {
            final file =
                await fileService.stat(_webDavPath(spaceProviderId, path));
            if (file == null) {
              // [FileService.stat] returns null only when no server is
              // configured at all (see its own doc) - every real "not found"
              // response throws, caught below. Treating this as "not
              // connected" rather than "path free" matters: the latter
              // would let an upload proceed with no server to receive it.
              throw const GalleryUploadException('Not connected to Seraph.');
            }
            return file.size;
          } on DioException catch (e) {
            if (e.response?.statusCode == 404) {
              // "Path is free" - not a token failure and not an error. A
              // 404 means the gateway accepted the token and looked the
              // path up; an expired token would have been a 403 before the
              // path was even considered, so this never reaches
              // [withTokenRecovery]'s refresh branch.
              return null;
            }
            rethrow;
          }
        },
        refreshToken: _refreshToken,
        translate: translateWebDavError,
      );
    } on GalleryUploadException {
      rethrow;
    }
  }

  @override
  Future<void> put(String spaceProviderId, String path, Uint8List bytes) async {
    try {
      await withTokenRecovery<void>(
        op: () async =>
            fileService.writeBytes(_webDavPath(spaceProviderId, path), bytes),
        refreshToken: _refreshToken,
        translate: translateWebDavError,
      );
    } on StateError catch (e) {
      // [FileService.writeBytes] throws this when no server is configured at
      // all - the same "not connected" case [statSize] recognises via a null
      // [FileService.stat] result. [withTokenRecovery] only catches
      // [DioException], so this propagates straight through to here.
      throw GalleryUploadException(e.message);
    }
  }

  @override
  Future<void> remove(String spaceProviderId, String path) async {
    try {
      await withTokenRecovery<void>(
        op: () async {
          try {
            await fileService.removeFile(_webDavPath(spaceProviderId, path));
          } on DioException catch (e) {
            if (e.response?.statusCode == 404) {
              // Already gone - not an error (see this method's doc on the
              // interface), and not a token failure (a 404 means the token
              // was accepted; an expired one would have been a 403).
              return;
            }
            rethrow;
          }
        },
        refreshToken: _refreshToken,
        translate: translateWebDavError,
      );
    } on StateError catch (e) {
      throw GalleryUploadException(e.message);
    }
  }
}
