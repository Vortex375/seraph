
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_browser_controller.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/file_browser/selection_controller.dart';
import 'package:seraph_app/src/share/share_controller.dart';
import 'package:webdav_client/webdav_client.dart';

class FileBrowserListView extends StatelessWidget{

  final SelectionController selectionController;
  final FileService fileService;
  final List<File> items;

  const FileBrowserListView({
    super.key, 
    required this.selectionController, 
    required this.fileService,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    ShareController shareController = Get.find();
    
    return ListView.builder(
      // Providing a restorationId allows the ListView to restore the
      // scroll position when a user leaves and returns to the app after it
      // has been killed while running in the background.
      restorationId: 'fileBrowserListView',
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        final item = items[index];
        final selected = selectionController.isSelected(item.path);
    
        final bool hasPreview = fileService.isImageFile(item);
        final Widget icon;
        if (item.isDir ?? false) {
          // icon = const SizedBox(height: 64, width: 64);
          icon = const Icon(Icons.folder, size: 24);
        } else if (hasPreview) {
          icon = fileService.getPreviewImage(item.path!, 64, 64);
        } else {
          icon = const Icon(Icons.description, size: 24);
        }
    
        return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
            title: Text('${item.name}', overflow: TextOverflow.ellipsis),
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selectionController.isSelecting.value) Checkbox(
                  value: selected, 
                  onChanged: (v) => selectItem(item, v ?? false)
                ),
                if (selectionController.isSelecting.value) const SizedBox(width: 4),
                Hero(tag: "preview:${item.path}", child: icon),
              ],
            ),
            trailing: Obx(() => shareController.isShared(item.path!)
            ? IconButton(
              icon: const Icon(Icons.share), 
              onPressed: () => shareController.editShare(shareController.getShareFor(item.path!)!)
            )
            : PopupMenuButton(
                itemBuilder: (builder) => [
                  PopupMenuItem(
                    onTap: () => shareController.createShare(item),
                    child: const Row(
                      children: [
                        Icon(Icons.share),
                        Expanded(child: Text('Share')),
                      ],
                    )
                  )
                ]
              )),
            onTap: () {
              final FileBrowserController controller = Get.find();
              if (hasPreview) {
                controller.setPreviewWidgetFactory(() => fileService.getPreviewImage(item.path!, 64, 64));
              } else {
                controller.setPreviewWidgetFactory(null);
              }
              controller.openItem(item);
            },
            onLongPress: () => selectItem(item, ! selected),
          );
      },
    );
  }

  void selectItem(File item, bool selected) {
    final path = item.path;
    if (selected && path != null) {
      selectionController.add(path);
    } else if (path != null) {
      selectionController.remove(path);
    }
  }

}