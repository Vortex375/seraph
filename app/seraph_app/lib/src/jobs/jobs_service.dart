import 'package:dio/dio.dart';
import 'package:seraph_app/src/jobs/job_models.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/util.dart';

class JobsService {
  JobsService(this.settingsController, this.loginController, {Dio? dio})
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

  Future<List<Job>> list() async {
    final response = await dio.get<List<dynamic>>(
      '/api/jobs',
      options: Options(headers: await _getRequestHeaders()),
    );
    return (response.data ?? [])
        .map((e) => Job.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
