import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:webdav_client/webdav_client.dart';
import 'package:flutter/material.dart';

import '../login/login_service.dart';

class FileService {
  FileService(this.settingsController, this.loginService) {
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

  String getPreviewUrl(File file, int w, int h) {
    return "${settingsController.serverUrl}/preview?p=${file.path}&w=$w&h=$h&exact=false";
  }

  Image getPreviewImage(File file, int w, int h) {
    Map<String, String>? headers;
    if (loginService.currentUser != null) {
      headers = {
        "Authorization": "Bearer ${loginService.currentUser?.token.accessToken}"
      };
    }
    return Image.network(getPreviewUrl(file, w, h),
      headers: headers,
      fit: BoxFit.cover,
      width: w.toDouble(),
      height: h.toDouble(),
    );
  }
}
