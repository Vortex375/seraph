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

  Future<T> _getAi<T>(String path, Map<String, dynamic>? query,
          T Function(Map<String, dynamic>?) parse) =>
      _ai(() async {
        final response = await dio.get<Map<String, dynamic>>(
          path,
          queryParameters: query,
          options: Options(headers: await _getRequestHeaders()),
        );
        return parse(response.data);
      });

  Future<T> _ai<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (e) {
      final data = e.response?.data;
      if (e.response?.statusCode == 503 &&
          data is Map &&
          data['error'] == 'ai-unavailable') {
        throw const GalleryAiUnavailableException();
      }
      rethrow;
    }
  }

  /// Search hits in Space coordinates, best match first. Throws
  /// [GalleryAiUnavailableException] when the AI service is not available.
  Future<List<GallerySearchHit>> search(
      {String q = '', String? tag, String? personId}) {
    return _getAi(
        '/api/gallery/search',
        {
          if (q.isNotEmpty) 'q': q,
          if (tag != null) 'tag': tag,
          if (personId != null) 'person': personId,
        },
        GallerySearchHit.listFromJson);
  }

  Future<GalleryAnalysisStatus> analysisStatus() => _getAi(
      '/api/gallery/analysis/status', null, GalleryAnalysisStatus.fromJson);

  Future<List<GalleryPerson>> people() =>
      _getAi('/api/gallery/people', null, GalleryPerson.listFromJson);

  /// Renames a person (empty name makes them unnamed); returns the updated
  /// person.
  Future<GalleryPerson> renamePerson(String id, String name) => _ai(() async {
        final response = await dio.patch<Map<String, dynamic>>(
          '/api/gallery/people/$id',
          data: {'name': name},
          options: Options(headers: await _getRequestHeaders()),
        );
        final person = response.data?['person'];
        if (person is! Map<String, dynamic>) {
          throw Exception('Failed to rename person');
        }
        return GalleryPerson.fromJson(person);
      });

  /// Tags and faces of one photo, by Space coordinates.
  Future<GalleryPhotoAnalysis> photoAnalysis(String providerId, String path) =>
      _getAi(
          '/api/gallery/photos/analysis',
          {'providerId': providerId, 'path': path},
          GalleryPhotoAnalysis.fromJson);

  /// Assigns a face: to [personId], to a new person called [newPersonName],
  /// or - with neither - removes it from its person (`"personId": null`).
  Future<void> assignFace(String faceId,
          {String? personId, String? newPersonName}) =>
      _ai(() async {
        await dio.put<Map<String, dynamic>>(
          '/api/gallery/faces/$faceId/person',
          data: newPersonName != null
              ? {'newPersonName': newPersonName}
              : {'personId': personId},
          options: Options(headers: await _getRequestHeaders()),
        );
      });
}
