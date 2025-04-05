
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_browser_controller.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/media_player/audio_player_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:webdav_client/webdav_client.dart';

class FileViewerController extends GetxController {

  late int initialIndex;
  late List<File> files;
  late PageController pageController;
  late TransformationController transformationController;

  final Rx<bool> isZoomedIn = false.obs;
  final Rx<bool> isUiVisible = true.obs;

  ThemeMode? _themeMode;

  @override
  onInit() {
    super.onInit();
    final SettingsController settings = Get.find();
    final FileBrowserController fileBrowserController = Get.find();

    _themeMode = settings.themeMode.value;
    initialIndex = fileBrowserController.openItemIndex.value;
    files = fileBrowserController.files.value;
    pageController = PageController(initialPage: initialIndex);
    transformationController = TransformationController();

    scheduleMicrotask(() {
      _maybeChangeTheme(initialIndex);
    });

    pageController.addListener(() {
      final currentPage = pageController.page?.toInt() ?? -1;
      _maybeChangeTheme(currentPage);
    });

    transformationController.addListener(() {
      final scale = transformationController.value.getMaxScaleOnAxis();
      isZoomedIn.value = scale > 1.0;
    });
  }

  @override
  onClose() {
    super.onClose();
    /* restore original theme mode */
    Get.changeThemeMode(_themeMode ?? ThemeMode.system);
    pageController.dispose();
    transformationController.dispose();
  }

  Future<void> playAudioFile(int index) async {
    final AudioPlayerController mediaPlayerController = Get.find();
    final FileService fileService = Get.find();
    
    final initial = files[index].path!;
    final pl = files.where(fileService.isAudioFile).map((f) => f.path!).toList();

    await mediaPlayerController.setPlaylist(pl, pl.indexOf(initial));
    await mediaPlayerController.play();
  }

  Future<void> toggleUiVisible() async {
    if (isUiVisible.value) {
      isUiVisible(false);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    } else {
      isUiVisible(true);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  void _maybeChangeTheme(int currentPage) {
    final FileService fileService = Get.find();
    if (currentPage >= 0 && currentPage < files.length && fileService.isImageFile(files[currentPage])) {
      /* switch to dark theme for image viewing */
      Get.changeThemeMode(ThemeMode.dark);
    } else {
      Get.changeThemeMode(_themeMode ?? ThemeMode.system);
    }
  }
}
