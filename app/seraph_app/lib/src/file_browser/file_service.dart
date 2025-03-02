import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:webdav_client/webdav_client.dart';
import 'package:flutter/material.dart';

class FileService {
  FileService(this.settingsController, this.loginController) {
    settingsController.serverUrlConfirmed.listenAndPump((value) {
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
    if (loginController.currentUser.value != null) {
      c.setHeaders({"Authorization": "Bearer ${loginController.currentUser.value?.token.accessToken}"});
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
    if (loginController.currentUser.value != null) {
      headers = {
        "Authorization": "Bearer ${loginController.currentUser.value?.token.accessToken}"
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
