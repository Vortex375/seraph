import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:seraph_app/src/file_browser/file_browser_controller.dart';
import 'package:seraph_app/src/file_viewer/file_viewer_controller.dart';
import 'package:seraph_app/src/media_player/media_bottom_bar.dart';
import 'package:seraph_app/src/media_player/video_player_controller.dart';

import '../file_browser/file_service.dart';

class FileViewerView extends StatelessWidget{
  
  static const String routeName = '/view';
  final String? tag;

  const FileViewerView({super.key, this.tag});

  @override
  Widget build(BuildContext context) {
    final FileService fileService = Get.find();
    final FileViewerController controller = Get.find(tag: tag);
    final FileBrowserController fileBrowserController = Get.find();
    final VideoPlayerController videoPlayerController = Get.find();

    final Widget? previewWidget = fileBrowserController.getPreviewWidget();

    return Obx(() => Scaffold(
      appBar: !controller.isUiVisible.value ? null : AppBar(
        leading: videoPlayerController.open.value ? IconButton(onPressed: videoPlayerController.stop, icon: const Icon(Icons.arrow_back)) : null,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(icon: const Icon(Icons.open_in_new), onPressed: () {
            controller.openExternally();
          })
        ],
      ),
      bottomNavigationBar: AnimatedOpacity(
        opacity: controller.isUiVisible.value ? 1.0: 0.0,
        duration: const Duration(milliseconds: 200),
        child: const MediaBottomBar()
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
          if (fileService.isImageFile(file)) {
            return Center(
              child: Hero(
                tag: "preview:${file.path}",
                child: GestureDetector(
                  onTap: controller.toggleUiVisible,
                  child: Obx(() => InteractiveViewer(
                    transformationController: controller.transformationController,
                    maxScale: 4.0,
                    // Disable pan when not zoomed
                    panEnabled: controller.isZoomedIn.value,
                    child: fileService.getImage(file.path!, (context, child, loadingProgress) => 
                      (loadingProgress == null) ? SizedBox.expand(child: child) : (index == controller.initialIndex ? previewWidget : null) ?? Container())
                  )),
                ),
              ),
            );
          } else if (fileService.isAudioFile(file)) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('${file.name}'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      controller.playAudioFile(index);
                    }, 
                    child: const Text('Play')
                  )
                ]
              ),
            );
          } else if (fileService.isVideoFile(file)) {
            return Obx(() { 
              if (videoPlayerController.open.value) {
                return SafeArea(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SizedBox.expand(
                        child: Video(
                          controller: videoPlayerController.controller,
                          controls: MaterialVideoControls,
                        ),
                      ),
                    ),
                  ),
                );
              } else {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('${file.name}'),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () {
                          videoPlayerController.openFile(file.path!);
                        }, 
                        child: const Text('Play')
                      )
                    ]
                  ),
                );
              }
            });
          } else {
            return Center(child: Text('File Viewer ${file.name}'));
          }
        }
      )),
    ));
  }
}