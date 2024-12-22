import 'package:webdav_client/webdav_client.dart';

import '../login/login_service.dart';

class FileService {
  FileService(this.baseUrl, this.loginService) : client = newClient('$baseUrl/dav/foo', debug: false);

  final String baseUrl;
  final Client client;
  final LoginService loginService;

  Future<List<File>> readDir(String path) async {
    if (loginService.currentUser != null) {
      client.setHeaders({"Authorization": "Bearer ${loginService.currentUser?.token.accessToken}"});
    } else {
      client.setHeaders({});
    }
    return client.readDir(path);
  }
}
