import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/util.dart';
import 'package:webdav_client/webdav_client.dart';
import 'package:flutter/material.dart';

class FileService {
  FileService(this.settingsController, this.loginController) {
    if (settingsController.serverUrlConfirmed.value) {
      client = newClient('${settingsController.serverUrl}/dav/p', debug: false);
    }
    settingsController.serverUrlConfirmed.listen((value) {
      if (value) {
        client = newClient('${settingsController.serverUrl}/dav/p', debug: false);
      }
    });
  }

  final SettingsController settingsController;
  final LoginController loginController;
  Client? client;

  Future<List<File>> readDir(String path) async {
    Client? c = client;
    if (c == null) {
      return [];
    }
    await until(loginController.isInitialized, identity);
    if (loginController.currentUser.value != null) {
      c.setHeaders({"Authorization": "Bearer ${loginController.currentUser.value?.token.accessToken}"});
    } else {
      c.setHeaders({});
    }
    return c.readDir(path);
  }

  Future<File?> stat(String path) async {
    Client? c = client;
    if (c == null) {
      return null;
    }
    await until(loginController.isInitialized, identity);
    if (loginController.currentUser.value != null) {
      c.setHeaders({"Authorization": "Bearer ${loginController.currentUser.value?.token.accessToken}"});
    } else {
      c.setHeaders({});
    }
    return c.readProps(path);
  }

  String getFileUrl(String path) {
    return '${settingsController.serverUrl}/dav/p$path';
  }

  Image getImage(String path, [ImageLoadingBuilder? loadingBuilder]) {
    Map<String, String>? headers;
    if (loginController.currentUser.value != null) {
      headers = {
        "Authorization": "Bearer ${loginController.currentUser.value?.token.accessToken}"
      };
    }
    return Image.network(getFileUrl(path), headers: headers, loadingBuilder: loadingBuilder);
  }

  String getPreviewUrl(String path, int w, int h) {
    print("get preview url: ${settingsController.serverUrl}/preview?p=$path&w=$w&h=$h");
    return "${settingsController.serverUrl}/preview?p=$path&w=$w&h=$h";
  }

  Image getPreviewImage(String path, int w, int h) {
    Map<String, String>? headers;
    if (loginController.currentUser.value != null) {
      headers = {
        "Authorization": "Bearer ${loginController.currentUser.value?.token.accessToken}"
      };
    }
    return Image.network(getPreviewUrl(path, w, h),
      headers: headers,
      fit: BoxFit.cover,
      width: w.toDouble(),
      height: h.toDouble(),
    );
  }

  bool supportsPreviewImage(File file) {
    return file.mimeType?.startsWith("image/") ?? false;
  }
}
