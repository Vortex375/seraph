
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_browser_controller.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/media_player/audio_player_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webdav_client/webdav_client.dart';

class FileViewerController extends GetxController {

  late int initialIndex;
  late PageController pageController;
  late TransformationController transformationController;

  final RxList<File> files = RxList();
  final Rx<bool> isZoomedIn = false.obs;
  final Rx<bool> isUiVisible = true.obs;

  ThemeMode? _themeMode;

  @override
  onInit() {
    super.onInit();
    final SettingsController settings = Get.find();
    final FileBrowserController fileBrowserController = Get.find();
    final FileService fileService = Get.find();

    _themeMode = settings.themeMode.value;
    initialIndex = fileBrowserController.openItemIndex.value;
    if (initialIndex == -1) {
      print("NO FILE");
      initialIndex = 0;
      scheduleMicrotask(() async {
        String? path = Get.parameters['path'];
        if (path != null) {
          print("for path: ${path}");
          File? file = await fileService.stat(path);
          if (file != null) {
            // stat returns broken path, it seems, so fix it
            file.path = path;
            files.add(file);
            scheduleMicrotask(() {
              _maybeChangeTheme(initialIndex);
            });
          }
        }
      });
    } else {
      files.addAll(fileBrowserController.files.value);
      scheduleMicrotask(() {
        _maybeChangeTheme(initialIndex);
      });
    }

    pageController = PageController(initialPage: initialIndex);
    transformationController = TransformationController();

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

  Future<void> openExternally() async {
    final FileService fileService = Get.find();
    if (kIsWeb) {
      await launchUrl(Uri.parse(fileService.getFileUrl(files[pageController.page!.toInt()].path!)),
          webOnlyWindowName: '_blank');
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
