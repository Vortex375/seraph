import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/media_player/audio_handler.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/share/share_controller.dart';

import 'src/app.dart';

void main() async {
  // Required or Android app hangs on startup
  WidgetsFlutterBinding.ensureInitialized();
  // Necessary initialization for package:media_kit.
  MediaKit.ensureInitialized();

  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());

  await Get.putAsync(() async =>
    await AudioService.init(
    builder: () => MyAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'net.umbasa.seraph_app.channel.audio',
      androidNotificationChannelName: 'Seraph - Music playback',
    ),
  ));

  const secureStorage = FlutterSecureStorage();

  // Load the user's preferred theme while the splash screen is displayed.
  // This prevents a sudden theme change when the app is first displayed.
  final settingsController = await Get.putAsync(() async {
    final controller = SettingsController();
    await controller.init();
    return controller;
  }, permanent: true);

  final shareController = Get.put(ShareController());
  await shareController.init();

  Get.put(LoginController(
    secureStorage: secureStorage, 
    settingsController: settingsController,
    shareController: shareController
  ), permanent: true);
  
  runApp(const MyApp());
}
