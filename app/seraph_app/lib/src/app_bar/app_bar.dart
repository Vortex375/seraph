import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:seraph_app/src/gallery/gallery_view.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';

import '../file_browser/file_browser.dart';
import '../settings/settings_view.dart';

AppBar seraphAppBar(BuildContext context, {
    String name = '', 
    String routeName = '',
    List<Widget> actions = const [], 
    PreferredSizeWidget? bottom
  }) {

  final settingsController = Get.find<SettingsController>();
  final loginController = Get.find<LoginController>();

  final logoutButton = IconButton(
    icon: const Icon(Icons.logout),
    onPressed: () {
      settingsController.setServerUrlConfirmed(false);
      loginController.logout();
    },
  );

  return AppBar(
    title: Row(
      children: [
        const Text('Seraph'),
        const SizedBox(width: 16),
        DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: routeName,
            items: const [
              DropdownMenuItem(
                  value: FileBrowser.routeName, child: Text('Cloud Files')),
              DropdownMenuItem(
                  value: GalleryView.routeName, child: Text('Gallery')),
              DropdownMenuItem(enabled: false, child: Divider()),
              DropdownMenuItem(
                  value: SettingsView.routeName, child: Text('App Settings'))
            ],
            onChanged: (value) => Get.offNamed(value!),
          ),
        ),
      ],
    ),
    actions: [...actions, logoutButton],
    bottom: bottom,
  );
}
