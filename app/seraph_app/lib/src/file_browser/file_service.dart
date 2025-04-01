import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/share/share_controller.dart';
import 'package:seraph_app/src/util.dart';
import 'package:webdav_client/webdav_client.dart';
import 'package:flutter/material.dart';

class FileService {
  FileService(this.settingsController, this.loginController, this.shareController) {
    pathPrefix = shareController.shareMode.value ? '/dav/s' : '/dav/p';

    if (settingsController.serverUrlConfirmed.value) {
      client = newClient('${settingsController.serverUrl}$pathPrefix', debug: false);
    }
    settingsController.serverUrlConfirmed.listen((value) {
      if (value) {
        client = newClient('${settingsController.serverUrl}$pathPrefix', debug: false);
      }
    });
  }

  final SettingsController settingsController;
  final LoginController loginController;
  final ShareController shareController;
  
  late String pathPrefix;

  Client? client;

  Future<Map<String, String>> getRequestHeaders() async {
    await until(loginController.isInitialized, identity);

    if (loginController.currentUser.value != null) {
      return {"Authorization": "Bearer ${loginController.currentUser.value?.token.accessToken}"};
    } else {
      return {};
    }
  }

  Map<String, String> getRequestHeadersSync() {
    if (loginController.currentUser.value != null) {
      return {"Authorization": "Bearer ${loginController.currentUser.value?.token.accessToken}"};
    } else {
      return {};
    }
  }

  Future<List<File>> readDir(String path) async {
    Client? c = client;
    if (c == null) {
      return [];
    }
    final headers = await getRequestHeaders();
    c.setHeaders(headers);
    return c.readDir(path);
  }

  Future<File?> stat(String path) async {
    Client? c = client;
    if (c == null) {
      return null;
    }
    final headers = await getRequestHeaders();
    c.setHeaders(headers);
    return c.readProps(path);
  }

  String getFileUrl(String path) {
    return '${settingsController.serverUrl}$pathPrefix$path';
  }

  Image getImage(String path, [ImageLoadingBuilder? loadingBuilder]) {
    final headers = getRequestHeadersSync();
    return Image.network(getFileUrl(path), headers: headers, loadingBuilder: loadingBuilder);
  }

  String getPreviewUrl(String path, int w, int h) {
    if (shareController.shareMode.value) {
      return "${settingsController.serverUrl}/preview?s=$path&w=$w&h=$h";
    } else {
      return "${settingsController.serverUrl}/preview?p=$path&w=$w&h=$h";
    }
  }

  Image getPreviewImage(String path, int w, int h) {
    final headers = getRequestHeadersSync();
    return Image.network(getPreviewUrl(path, w, h),
      headers: headers,
      fit: BoxFit.cover,
      width: w.toDouble(),
      height: h.toDouble(),
    );
  }

  bool isImageFile(File file) {
    return file.mimeType?.startsWith("image/") ?? false;
  }

  bool isAudioFile(File file) {
    return file.mimeType?.startsWith("audio/") ?? false;
  }
}
