
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_browser_controller.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/file_browser/selection_controller.dart';
import 'package:webdav_client/webdav_client.dart';

class FileBrowserGridView extends StatelessWidget {

  final SelectionController selectionController;
  final FileService fileService;
  final List<File> items;
  final double gridSize;

  const FileBrowserGridView({
    super.key, 
    required this.selectionController, 
    required this.fileService,
    required this.items,
    required this.gridSize,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      // Providing a restorationId allows the ListView to restore the
      // scroll position when a user leaves and returns to the app after it
      // has been killed while running in the background.
      restorationId: 'fileBrowserGridView',
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: gridSize,
      ),
      itemCount: items.length,
      itemBuilder: (BuildContext context, int index) {
        final item = items[index];
        final selected = selectionController.isSelected(item.path);
        final hasPreview = fileService.isImageFile(item);

        return LayoutBuilder(
          builder: (context, constraints) {
            final Widget icon;
            if (item.isDir ?? false) {
              icon = const Icon(Icons.folder, size: 48);
            } else if (hasPreview) {
              icon = Hero(
                tag: "preview:${item.path}",
                child: fileService.getPreviewImage(item.path!, constraints.maxWidth.toInt(), constraints.maxWidth.toInt())
              );
            } else {
              icon = const Icon(Icons.description, size: 48);
            }

            return InkWell(
              onTap: () {
                final FileBrowserController controller = Get.find();
                if (hasPreview) {
                  controller.setPreviewWidgetFactory(() => 
                    fileService.getPreviewImage(item.path!, constraints.maxWidth.toInt(), constraints.maxWidth.toInt()));
                } else {
                  controller.setPreviewWidgetFactory(null);
                }
                controller.openItem(item);
              },
              onLongPress: () => selectItem(item, !selected),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: icon
                  ),
                  Align(
                    alignment: Alignment.bottomLeft,
                    child: _withBackground(context, selectionController.isSelecting.value, InkWell(
                      onTap: selectionController.isSelecting.value ? () => selectItem(item, !selected) : null,
                      child: Row(
                        children: [
                          if (selectionController.isSelecting.value) Checkbox(
                            value: selected, 
                            onChanged: (v) => selectItem(item, v ?? false)
                          ),
                          if (selectionController.isSelecting.value) const SizedBox(width: 4),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(4.0),
                              child: hasPreview ? _outlinedText('${item.name}')
                                : Text('${item.name}',
                                softWrap: false,
                                overflow: TextOverflow.fade,
                              )
                            ),
                          )
                        ]
                      ),
                    )),
                  )
                ],
              ),
            );
          }
        );
      },
    );
  }

  Widget _outlinedText(String t) {
    return Stack(
      children: [
        // Stroke (Outline)
        Text(
          t,
          softWrap: false,
          overflow: TextOverflow.fade,
          style: TextStyle(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.bevel
              ..strokeWidth = 3 // Thickness of the outline
              ..color = Colors.black,
          ),
        ),
        // Fill (White Text)
        Text(
          t,
          softWrap: false,
          overflow: TextOverflow.fade,
          style: const TextStyle(
            color: Colors.white,
          ),
        ),
      ],
    );
  }

  Widget _withBackground(BuildContext context, bool enable, Widget w) {
    return enable ? Material(
          color: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.8),
          child: w
        ) : w;
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