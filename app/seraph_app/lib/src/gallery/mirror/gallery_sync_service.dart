import 'package:dio/dio.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_delta_models.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/util.dart';

/// Drives [GalleryMirror] from the gallery service's delta feed
/// (`GET /api/gallery/delta` on the api-gateway,
/// `gallery/gallery/messages.go` `GalleryDeltaRequest`/`GalleryDeltaResponse`).
///
/// A cold start (mirror has never synced, [GalleryMirror.since] is 0) and a
/// resumed sync (some `since`/`pendingCursor` already stored) are the same
/// code path here - `since=0` is exactly what the server treats as "the
/// beginning" (see `GalleryDeltaRequest.Since` doc), so there is no separate
/// "first sync" branch to keep in sync with the resume logic.
class GallerySyncService {
  GallerySyncService(
    this.settingsController,
    this.loginController,
    this.mirror, {
    Dio? dio,
  }) : dio = dio ??
            Dio(BaseOptions(baseUrl: settingsController.serverUrl.value)) {
    settingsController.serverUrl.listen((url) {
      this.dio.options.baseUrl = url;
    });
  }

  final SettingsController settingsController;
  final LoginController loginController;
  final GalleryMirror mirror;
  final Dio dio;

  Future<Map<String, String>> _getRequestHeaders() async {
    await until(loginController.isInitialized, identity);

    if (loginController.currentUser.value != null) {
      return {
        'Authorization':
            'Bearer ${loginController.currentUser.value?.token.accessToken}'
      };
    }

    return {};
  }

  /// Runs one full poll: fetches and applies delta pages until the server
  /// reports `hasMore: false`, i.e. until the mirror has caught up with
  /// everything the feed has for this user right now.
  ///
  /// Each page is applied (and its progress persisted) before the next page
  /// is requested - see [GalleryMirror.applyPage] - so a poll interrupted
  /// between pages (app killed, network dropped) leaves the mirror exactly
  /// as far along as its last successfully applied page, with
  /// [GalleryMirror.pendingCursor] pointing at where to resume, not at a gap
  /// and not at a duplicate.
  Future<void> sync() async {
    final since = await mirror.since();
    var cursor = await mirror.pendingCursor();

    while (true) {
      final page = await _fetchPage(since: since, cursor: cursor);
      await mirror.applyPage(page);

      if (!page.hasMore) {
        return;
      }
      cursor = page.nextCursor;
    }
  }

  Future<GalleryDeltaResponse> _fetchPage({
    required int since,
    String? cursor,
  }) async {
    final response = await dio.get<Map<String, dynamic>>(
      '/api/gallery/delta',
      queryParameters: {
        'since': since,
        if (cursor != null && cursor.isNotEmpty) 'cursor': cursor,
      },
      options: Options(headers: await _getRequestHeaders()),
    );

    return GalleryDeltaResponse.fromJson(response.data ?? const {});
  }
}
