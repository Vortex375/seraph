import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';

import 'src/app.dart';

void main() async {
  // Required or Android app hangs on startup
  WidgetsFlutterBinding.ensureInitialized();

  const secureStorage = FlutterSecureStorage();

  // Load the user's preferred theme while the splash screen is displayed.
  // This prevents a sudden theme change when the app is first displayed.
  final settingsController = await Get.putAsync(() async {
    final controller = SettingsController();
    await controller.init();
    return controller;
  }, permanent: true);

  Get.put(LoginController(secureStorage: secureStorage, settingsController: settingsController));

  final fileService = FileService(Get.find(), Get.find());
  
  runApp(MyApp(fileService: fileService));
}
