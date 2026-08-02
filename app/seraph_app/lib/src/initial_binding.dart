import 'package:get/get.dart';
import 'package:seraph_app/src/chat/chat_controller.dart';
import 'package:seraph_app/src/chat/chat_service.dart';
import 'package:seraph_app/src/file_browser/file_browser_controller.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/file_browser/selection_controller.dart';
import 'package:seraph_app/src/gallery/gallery_service.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_sync_service.dart';
import 'package:seraph_app/src/media_player/audio_player_controller.dart';
import 'package:seraph_app/src/search/search_service.dart';
import 'package:seraph_app/src/spaces_admin/spaces_list_controller.dart';
import 'package:seraph_app/src/spaces_admin/spaces_service.dart';

class InitialBinding extends Bindings {
  @override
  void dependencies() {
    Get.put(FileService(Get.find(), Get.find(), Get.find()));
    Get.put(SearchService(Get.find(), Get.find()));
    Get.put(ChatService(Get.find(), Get.find()));
    Get.put(ChatController(Get.find()));
    Get.put(SelectionController());
    Get.put(FileBrowserController());
    Get.put(AudioPlayerController());
    Get.put(SpacesService(Get.find(), Get.find()));
    Get.put(SpacesListController(Get.find()));
    Get.put(GalleryService(Get.find(), Get.find()));
    final galleryMirrorDatabase = Get.put(GalleryMirrorDatabase.open());
    final galleryMirror = Get.put(GalleryMirror(galleryMirrorDatabase));
    Get.put(GallerySyncService(Get.find(), Get.find(), galleryMirror));
  }

}
