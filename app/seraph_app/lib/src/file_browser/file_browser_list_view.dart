
import 'package:flutter/material.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/file_browser/selection_controller.dart';
import 'package:webdav_client/webdav_client.dart';

class FileBrowserListView extends StatelessWidget{

  final SelectionController selectionController;
  final ScrollController scrollController;
  final FileService fileService;
  final List<File> items;
  final Function(File)? onOpen;

  const FileBrowserListView({
    super.key, 
    required this.selectionController, 
    required this.scrollController,
    required this.fileService,
    required this.items,
    this.onOpen
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      // Providing a restorationId allows the ListView to restore the
      // scroll position when a user leaves and returns to the app after it
      // has been killed while running in the background.
      restorationId: 'fileBrowserListView',
      controller: scrollController,
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        final item = items[index];
        final selected = selectionController.isSelected(item.path);
    
        final Widget icon;
        if (item.isDir ?? false) {
          // icon = const SizedBox(height: 64, width: 64);
          icon = const Icon(Icons.folder, size: 24);
        } else if (hasPreview(item)) {
          icon = fileService.getPreviewImage(item, 64, 64);
        } else {
          icon = const Icon(Icons.description, size: 24);
        }
    
        return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
            title: Text('${item.name}', overflow: TextOverflow.ellipsis),
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selectionController.isSelecting) Checkbox(
                  value: selected, 
                  onChanged: (v) => selectItem(item, v ?? false)
                ),
                if (selectionController.isSelecting) const SizedBox(width: 4),
                icon,
              ],
            ),
            onTap: () => openItem(item),
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

  hasPreview(File file) {
    if (file.mimeType == "image/jpeg" || file.mimeType == "image/png" || file.mimeType == "image/gif ") {
      return true;
    }
    return false;
  }

  openItem(File item) {
    if (onOpen != null) {
      onOpen!(item);
    }
  }

}