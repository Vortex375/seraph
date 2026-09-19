import 'package:dio/dio.dart';
import 'package:seraph_app/src/gallery/gallery_models.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/util.dart';

/// Talks to the gallery service through the api-gateway.
///
/// The set of Gallery Source Folders is held on the server against the user's
/// account, so a second device and the web UI see the same set.
class GalleryService {
  GalleryService(this.settingsController, this.loginController, {Dio? dio})
      : dio = dio ??
            Dio(BaseOptions(baseUrl: settingsController.serverUrl.value)) {
    settingsController.serverUrl.listen((url) {
      this.dio.options.baseUrl = url;
    });
  }

  final SettingsController settingsController;
  final LoginController loginController;
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

  Future<List<GallerySourceFolder>> listSourceFolders() async {
    final response = await dio.get<Map<String, dynamic>>(
      '/api/gallery/source-folders',
      options: Options(headers: await _getRequestHeaders()),
    );

    final rawList = response.data?['sourceFolder'];
    if (rawList is! List) return [];
    return rawList
        .map((item) =>
            GallerySourceFolder.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  /// Adds a Gallery Source Folder. Adding the same folder twice is idempotent
  /// on the server, so the caller does not have to check first.
  Future<GallerySourceFolder> addSourceFolder(
      String spaceProviderId, String path) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/api/gallery/source-folders',
      data: {
        'spaceProviderId': spaceProviderId,
        'path': path,
      },
      options: Options(headers: await _getRequestHeaders()),
    );

    final rawList = response.data?['sourceFolder'];
    if (rawList is List && rawList.isNotEmpty) {
      return GallerySourceFolder.fromJson(rawList[0] as Map<String, dynamic>);
    }
    throw Exception('Failed to add gallery source folder');
  }

  /// Removes a Gallery Source Folder from the user's configuration.
  /// This deletes no files.
  Future<void> removeSourceFolder(String id) async {
    await dio.delete<Map<String, dynamic>>(
      '/api/gallery/source-folders/$id',
      options: Options(headers: await _getRequestHeaders()),
    );
  }

  /// Triggers a genuine File Provider re-scan of a Gallery Source Folder, so
  /// photos present on disk but missing from the (potentially stale) File
  /// Index appear in the gallery. Runs in the background on the server;
  /// callers should re-fetch [listSourceFolders] to observe
  /// [GallerySourceFolder.rescanRunning] flip back to false when it finishes.
  /// Safe to call again while a rescan is already running - the server does
  /// not start a second one.
  Future<GallerySourceFolder> rescanSourceFolder(String id) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/api/gallery/source-folders/$id/rescan',
      options: Options(headers: await _getRequestHeaders()),
    );

    final rawList = response.data?['sourceFolder'];
    if (rawList is List && rawList.isNotEmpty) {
      return GallerySourceFolder.fromJson(rawList[0] as Map<String, dynamic>);
    }
    throw Exception('Failed to rescan gallery source folder');
  }
}
