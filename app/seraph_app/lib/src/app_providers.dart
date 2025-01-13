import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'file_browser/file_service.dart';
import 'login/login_service.dart';
import 'settings/settings_controller.dart';

class AppProviders extends StatelessWidget {

  const AppProviders({
    super.key,
    required this.settingsController,
    required this.loginService,
    required this.fileService,
    required this.child
  });

  final SettingsController settingsController;
  final LoginService loginService;
  final FileService fileService;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: settingsController,
      child: ChangeNotifierProvider.value(
        value: loginService,
        child: MultiProvider(
          providers: [
            Provider.value(value: fileService)
          ],
          child: child,
        )
      ),
    );
  }
}