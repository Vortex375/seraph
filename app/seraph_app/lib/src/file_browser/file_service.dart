import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:webdav_client/webdav_client.dart';
import 'package:flutter/material.dart';

import '../login/login_service.dart';

class FileService {
  FileService(this.settingsController, this.loginService) {
      if (settingsController.serverUrlConfirmed) {
        client = newClient('${settingsController.serverUrl}/dav/p', debug: false);
      }
    settingsController.addListener(() {
      if (settingsController.serverUrlConfirmed) {
        client = newClient('${settingsController.serverUrl}/dav/p', debug: false);
      }
    });
  }

  final SettingsController settingsController;
  final LoginService loginService;
  Client? client;

  Future<List<File>> readDir(String path) async {
    Client? c = client;
    if (c == null) {
      return [];
    }
    if (loginService.currentUser != null) {
      c.setHeaders({"Authorization": "Bearer ${loginService.currentUser?.token.accessToken}"});
    } else {
      c.setHeaders({});
    }
    return c.readDir(path);
  }

  String getPreviewUrl(File file) {
    return "${settingsController.serverUrl}/preview?p=${file.path}&w=64&h=64&exact=false";
  }

  Image getPreviewImage(File file) {
    Map<String, String>? headers;
    if (loginService.currentUser != null) {
      headers = {
        "Authorization": "Bearer ${loginService.currentUser?.token.accessToken}"
      };
    }
    return Image.network(getPreviewUrl(file),
      headers: headers,
      fit: BoxFit.cover,
      width: 48,
      height: 48,
    );
  }
}
