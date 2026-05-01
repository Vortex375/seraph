import 'package:dio/dio.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/spaces_admin/spaces_models.dart';
import 'package:seraph_app/src/util.dart';

class SpacesService {
  SpacesService(this.settingsController, this.loginController, {Dio? dio})
      : dio = dio ??
            Dio(BaseOptions(baseUrl: settingsController.serverUrl.value));

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

  Future<List<Space>> listSpaces() async {
    final response = await dio.get<Map<String, dynamic>>(
      '/api/spaces',
      options: Options(headers: await _getRequestHeaders()),
    );

    final rawList = response.data?['space'];
    if (rawList is! List) return [];
    return rawList
        .map((item) => Space.fromJson(item as Map<String, dynamic>))
        .toList();
  }

  Future<Space> getSpace(String spaceId) async {
    final response = await dio.get<Map<String, dynamic>>(
      '/api/spaces/$spaceId',
      options: Options(headers: await _getRequestHeaders()),
    );

    final rawList = response.data?['space'];
    if (rawList is List && rawList.isNotEmpty) {
      return Space.fromJson(rawList[0] as Map<String, dynamic>);
    }
    throw Exception('Space not found');
  }

  Future<Space> createSpace(Space space) async {
    final response = await dio.post<Map<String, dynamic>>(
      '/api/spaces',
      data: space.toJson(),
      options: Options(headers: await _getRequestHeaders()),
    );

    final rawList = response.data?['space'];
    if (rawList is List && rawList.isNotEmpty) {
      return Space.fromJson(rawList[0] as Map<String, dynamic>);
    }
    throw Exception('Failed to create space');
  }

  Future<Space> updateSpace(String spaceId, Space space) async {
    final response = await dio.put<Map<String, dynamic>>(
      '/api/spaces/$spaceId',
      data: space.toJson(),
      options: Options(headers: await _getRequestHeaders()),
    );

    final rawList = response.data?['space'];
    if (rawList is List && rawList.isNotEmpty) {
      return Space.fromJson(rawList[0] as Map<String, dynamic>);
    }
    throw Exception('Failed to update space');
  }

  Future<void> deleteSpace(String spaceId) async {
    await dio.delete<void>(
      '/api/spaces/$spaceId',
      options: Options(headers: await _getRequestHeaders()),
    );
  }

  Future<List<ServiceAnnouncement>> listServices() async {
    final response = await dio.get<List<dynamic>>(
      '/api/services',
      options: Options(headers: await _getRequestHeaders()),
    );

    if (response.data == null) return [];
    return response.data!
        .map((item) =>
            ServiceAnnouncement.fromJson(item as Map<String, dynamic>))
        .toList();
  }
}
