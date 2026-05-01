import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/chat/chat_view.dart';
import 'package:seraph_app/src/file_browser/file_browser_view.dart';
import 'package:seraph_app/src/gallery/gallery_view.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/share/share_controller.dart';
import 'package:seraph_app/src/spaces_admin/spaces_list_view.dart';
import '../settings/settings_view.dart';

AppBar seraphAppBar(BuildContext context, {
  String name = '',
  String routeName = '',
  List<Widget> actions = const [],
  PreferredSizeWidget? bottom,
}) {
  final ShareController shareController = Get.find();
  final bool hasLoginController = Get.isRegistered<LoginController>();

  return AppBar(
    title: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Flexible(
          fit: FlexFit.loose,
          child: Text('Seraph', overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 12),
        if (!shareController.shareMode.value)
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: _buildNavDropdown(hasLoginController, routeName),
            ),
          ),
        if (shareController.shareMode.value)
          Expanded(
            child: Text(
              shareController.title.value ?? '',
              style: const TextStyle(fontSize: 18),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    ),
    actions: actions,
    bottom: bottom,
  );
}

Widget _buildNavDropdown(bool hasLoginController, String routeName) {
  if (!hasLoginController) {
    return _buildDropdown(false, routeName);
  }
  return Obx(() {
    final isAdmin = Get.find<LoginController>().isSpaceAdmin.value;
    return _buildDropdown(isAdmin, routeName);
  });
}

Widget _buildDropdown(bool isAdmin, String currentRoute) {
  final items = <DropdownMenuItem<String>>[
    const DropdownMenuItem(
        value: FileBrowserView.routeName,
        child: Text('Cloud Files', overflow: TextOverflow.ellipsis)),
    const DropdownMenuItem(
        value: GalleryView.routeName,
        child: Text('Gallery', overflow: TextOverflow.ellipsis)),
    const DropdownMenuItem(
        value: ChatView.routeName,
        child: Text('Chat', overflow: TextOverflow.ellipsis)),
    if (isAdmin)
      const DropdownMenuItem(
          value: SpacesListView.routeName,
          child: Text('Spaces Admin', overflow: TextOverflow.ellipsis)),
    const DropdownMenuItem(enabled: false, child: Divider()),
    const DropdownMenuItem(
        value: SettingsView.routeName,
        child: Text('App Settings', overflow: TextOverflow.ellipsis)),
  ];

  return DropdownButtonHideUnderline(
    child: DropdownButton<String>(
      isExpanded: true,
      value: currentRoute,
      items: items,
      onChanged: (value) => Get.offAllNamed(value!),
    ),
  );
}
