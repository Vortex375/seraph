
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:webdav_client/webdav_client.dart';

class FileViewerController extends GetxController {

  FileViewerController({required this.fileName, required this.hasPreview});

  final String fileName;
  final bool hasPreview;
  final Rx<File?> file = Rx(null);

  ThemeMode? _themeMode;

  @override
  onInit() {
    super.onInit();
    scheduleMicrotask(() async {
      _themeMode = Get.find<SettingsController>().themeMode.value;

      final FileService fileService = Get.find();
      try {
        file.value = await fileService.stat(fileName);
        if (file.value != null && fileService.supportsPreviewImage(file.value!)) {
          /* switch to dark theme for image viewing */
          Get.changeThemeMode(ThemeMode.dark);
        }
      } catch (err) {
        _showError(err.toString());
      }
    });
  }

  @override
  onClose() {
    super.onClose();
    /* restore original theme mode */
    Get.changeThemeMode(_themeMode ?? ThemeMode.system);
  }

  void _showError(String error) {
    Get.snackbar('Load failed', error,
        backgroundColor: Colors.amber[800],
        isDismissible: true,
        snackPosition: SnackPosition.BOTTOM
      );
  }
}
