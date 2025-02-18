import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:go_router/go_router.dart';
import 'package:seraph_app/src/gallery/gallery_view.dart';
import 'package:seraph_app/src/login/login_service.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';

import '../file_browser/file_browser.dart';
import '../settings/settings_view.dart';

AppBar seraphAppBar(BuildContext context, {
    String name = '', 
    String routeName = '',
    List<Widget> actions = const [], 
    PreferredSizeWidget? bottom
  }) {

  final settings = context.watch<SettingsController>();
  final loginService = context.watch<LoginService>();

  final logoutButton = IconButton(
    icon: const Icon(Icons.logout),
    onPressed: () {
      settings.confirmServerUrl(false);
      loginService.logout();
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
            onChanged: (value) => GoRouter.of(context).go(value!),
          ),
        ),
      ],
    ),
    actions: [...actions, logoutButton],
    bottom: bottom,
  );
}
