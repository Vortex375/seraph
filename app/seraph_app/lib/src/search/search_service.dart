import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/util.dart';

class SearchService {
  final SettingsController settingsController;
  final LoginController loginController;
  final Dio dio;

  SearchService(this.settingsController, this.loginController)
      : dio = Dio(BaseOptions(baseUrl: settingsController.serverUrl.value));

  Stream<Map<String, dynamic>> search(String query) async* {
    await until(loginController.isInitialized, identity);

    Map<String, dynamic> authHeaders;
    if (loginController.currentUser.value != null) {
      authHeaders = {
        "Authorization":
            "Bearer ${loginController.currentUser.value?.token.accessToken}"
      };
    } else {
      authHeaders = {};
    }

    final response = await dio.get<ResponseBody>(
      '/api/search',
      queryParameters: {"q": query},
      options: Options(
        responseType: ResponseType.stream,
        headers: {
          'Accept': 'application/x-ndjson',
          ...authHeaders
        },
      ),
    );

    final stream = response.data!.stream
        .cast<List<int>>()
        .transform(utf8.decoder) // Convert bytes to string
        .transform(const LineSplitter()); // Split by lines

    await for (final line in stream) {
      if (line.trim().isEmpty) continue;
      try {
        yield json.decode(line) as Map<String, dynamic>;
      } catch (e) {
        print('Failed to decode line: $line');
      }
    }
  }
}
