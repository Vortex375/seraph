import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_browser_view.dart';

import 'package:seraph_app/src/gallery/gallery_view.dart';
import 'package:seraph_app/src/share/share_controller.dart';

import '../settings/settings_view.dart';

AppBar seraphAppBar(BuildContext context, {
    String name = '', 
    String routeName = '',
    List<Widget> actions = const [], 
    PreferredSizeWidget? bottom
  }) {

  final ShareController shareController = Get.find();

  return AppBar(
    title: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Text('Seraph'),
        const SizedBox(width: 16),
        if (!shareController.shareMode.value) DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: routeName,
            items: const [
              DropdownMenuItem(
                  value: FileBrowserView.routeName, child: Text('Cloud Files')),
              DropdownMenuItem(
                  value: GalleryView.routeName, child: Text('Gallery')),
              DropdownMenuItem(enabled: false, child: Divider()),
              DropdownMenuItem(
                  value: SettingsView.routeName, child: Text('App Settings'))
            ],
            onChanged: (value) => Get.offAllNamed(value!),
          ),
        ),
        if (shareController.shareMode.value) Text(shareController.title.value ?? '', style: const TextStyle(fontSize: 18))
      ],
    ),
    actions: actions,
    bottom: bottom,
  );
}
