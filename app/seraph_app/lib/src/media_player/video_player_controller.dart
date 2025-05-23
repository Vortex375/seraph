
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';

class VideoPlayerController extends GetxController {

  final RxBool open = false.obs;
  final RxBool playing = false.obs;
  final RxBool buffering = false.obs;
  final Rx<Duration> position = Rx(const Duration());

  late final Player player = Player();
  late final controller = VideoController(player);

  ThemeMode? _themeMode;

  @override
  onInit() {
    super.onInit();

    final SettingsController settings = Get.find();
    _themeMode = settings.themeMode.value;
  }

  Future<void> openFile(String path) async {
    final FileService fileService = Get.find();
    final url = fileService.getFileUrl(path);
    final headers = await fileService.getRequestHeaders();

    await player.stop();
    await player.open(Media(url, httpHeaders: headers));
    open.value = true;
    Get.changeThemeMode(ThemeMode.dark);
    await player.play();
  }

  Future<void> stop() async {
    Get.changeThemeMode(_themeMode ?? ThemeMode.system);
    open.value = false;
    player.stop();
  }

  @override
  void onClose() {
    Get.changeThemeMode(_themeMode ?? ThemeMode.system);
    open.value = false;
    player.dispose();
    super.onClose();
  }
}