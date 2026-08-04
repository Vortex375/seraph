import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
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

  // Opened here, ahead of LoginController, rather than in InitialBinding
  // (where the rest of Gallery Mode's wiring lives) - ticket 23's
  // cross-isolate token-refresh lock needs LoginController to hold a
  // GalleryMirror, and LoginController.init() already starts its own OIDC
  // refresh synchronously below, before GetMaterialApp's initialBinding
  // (InitialBinding) has necessarily run. GalleryMirrorDatabase.open() is
  // cheap - the connection itself is a LazyDatabase, opened only on first
  // query (see `gallery/mirror/connection/*.dart`) - and works on every
  // platform this app ships to, so opening it slightly earlier costs
  // nothing. InitialBinding reuses this SAME instance via Get.find rather
  // than opening a second connection to the same file.
  final galleryMirrorDatabase =
      Get.put(GalleryMirrorDatabase.open(), permanent: true);
  final galleryMirror =
      Get.put(GalleryMirror(galleryMirrorDatabase), permanent: true);

  Get.put(LoginController(
    secureStorage: secureStorage,
    settingsController: settingsController,
    shareController: shareController,
    galleryMirror: galleryMirror,
  ), permanent: true);

  runApp(const MyApp());
}
