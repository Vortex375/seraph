import 'package:webdav_client/webdav_client.dart';

class FileService {
  FileService(this.baseUrl) : client = newClient('$baseUrl/dav/foo', debug: false);

  final String baseUrl;
  final Client client;

  Future<List<File>> readDir(String path) async {
    return client.readDir(path);
  }
}
