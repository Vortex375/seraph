import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/chat/chat_view.dart';
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
        const Flexible(
          fit: FlexFit.loose,
          child: Text(
            'Seraph',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 12),
        if (!shareController.shareMode.value)
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  isExpanded: true,
                  value: routeName,
                  items: const [
                    DropdownMenuItem(
                        value: FileBrowserView.routeName, child: Text('Cloud Files', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(
                        value: GalleryView.routeName, child: Text('Gallery', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(
                        value: ChatView.routeName, child: Text('Chat', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(enabled: false, child: Divider()),
                    DropdownMenuItem(
                        value: SettingsView.routeName, child: Text('App Settings', overflow: TextOverflow.ellipsis))
                  ],
                  onChanged: (value) => Get.offAllNamed(value!),
                ),
              ),
            ),
          ),
        if (shareController.shareMode.value)
          Expanded(
            child: Text(
              shareController.title.value ?? '',
              style: const TextStyle(fontSize: 18),
              overflow: TextOverflow.ellipsis,
            ),
          )
      ],
    ),
    actions: actions,
    bottom: bottom,
  );
}
