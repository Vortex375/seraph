import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_browser_controller.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/file_browser/selection_controller.dart';
import 'package:seraph_app/src/media_player/audio_player_controller.dart';

class InitialBinding extends Bindings {
  @override
  void dependencies() {
    Get.put(FileService(Get.find(), Get.find(), Get.find()));
    Get.put(SelectionController());
    Get.put(FileBrowserController());
    Get.put(AudioPlayerController());
  }

}