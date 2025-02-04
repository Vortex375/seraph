import 'package:flutter/material.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/login/login_service.dart';

import 'src/app.dart';
import 'src/settings/settings_controller.dart';
import 'src/settings/settings_service.dart';

void main() async {
  // Required or Android app hangs on startup
  WidgetsFlutterBinding.ensureInitialized();

  // Set up the SettingsController, which will glue user settings to multiple
  // Flutter Widgets.
  final settingsController = SettingsController(SettingsService());

  // Load the user's preferred theme while the splash screen is displayed.
  // This prevents a sudden theme change when the app is first displayed.
  await settingsController.loadSettings();

  final loginService = LoginService();

  print("serverUrl: ${settingsController.serverUrl}");
  final fileService = FileService(settingsController, loginService);

  // Run the app and pass in the SettingsController. The app listens to the
  // SettingsController for changes, then passes it further down to the
  // SettingsView.
  runApp(MyApp(
    settingsController: settingsController,
    fileService: fileService,
    loginService: loginService));
}
