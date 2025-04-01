
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_browser_view.dart';
import 'package:seraph_app/src/share/share_controller.dart';

class ShareView extends StatelessWidget {

  const ShareView({super.key});

  @override
  Widget build(BuildContext context) {
    final ShareController shareController = Get.find();

    return Obx(() {
      if (!shareController.ready.value) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(
                "One moment please",
                style: TextStyle(fontSize: 18, color: Colors.grey[700]),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        );
      }
      if (shareController.fail.value) {
        return Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.not_interested, size: 80, color: Colors.grey),
              const SizedBox(height: 16),
              Text(
                "Sorry, there's nothing here",
                style: TextStyle(fontSize: 18, color: Colors.grey[700]),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        );
      } else {
        return const FileBrowserView();
      }
    });
  }
}