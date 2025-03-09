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
      body: Obx(() => PageView.builder(
        controller: controller.pageController,
        itemCount: controller.files.length,
        // Disable swipe when zoomed
        physics: controller.isZoomedIn.value ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
        itemBuilder: (context, index) {
          final file = controller.files[index];
          if (fileService.supportsPreviewImage(file)) {
            return Hero(
              tag: "preview:${file.path}",
              child: Center(
                child: Obx(() => InteractiveViewer(
                  transformationController: controller.transformationController,
                  // Disable pan when not zoomed
                  panEnabled: controller.isZoomedIn.value,
                  child: fileService.getImage(file.path!, (context, child, loadingProgress) => 
                    (loadingProgress == null) ? SizedBox.expand(child: child) : (index == controller.initialIndex ? previewWidget : null) ?? Container())
                )),
              ),
            );
          } else {
            return Text('File Viewer ${file.name}');
          }
        }
      )),
    );
  }
}