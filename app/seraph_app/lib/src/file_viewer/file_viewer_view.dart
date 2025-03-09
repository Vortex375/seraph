import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_browser_controller.dart';
import 'package:seraph_app/src/file_viewer/file_viewer_controller.dart';

import '../file_browser/file_service.dart';

class FileViewerView extends StatelessWidget{
  
  static const String routeName = '/view';

  const FileViewerView({super.key});

  @override
  Widget build(BuildContext context) {
    final FileService fileService = Get.find();
    final FileViewerController controller = Get.find();
    final FileBrowserController fileBrowserController = Get.find();

    final Widget? previewWidget = fileBrowserController.getPreviewWidget();

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
      ),
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: Obx(() {
        final file = controller.file.value;
        if (file == null) {
          if (previewWidget != null) {
            return Hero(
              tag: "preview:${controller.fileName}",
              child: Center(child: previewWidget)
            );
          } else {
            return Container();
          }
        } else {
          if (fileService.supportsPreviewImage(file)) {
            return Hero(
              tag: "preview:${controller.fileName}",
              child: Center(
                child: InteractiveViewer(
                  child: fileService.getImage(controller.fileName, (context, child, loadingProgress) => 
                    (loadingProgress == null) ? SizedBox.expand(child: child) : previewWidget ?? Container())
                ),
              ),
            );
          } else {
            return Text('File Viewer ${controller.file.value?.name}');
          }
        }
      }),
    );
  }
}