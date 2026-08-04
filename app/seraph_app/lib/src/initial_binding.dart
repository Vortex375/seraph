import 'package:get/get.dart';
import 'package:seraph_app/src/chat/chat_controller.dart';
import 'package:seraph_app/src/chat/chat_service.dart';
import 'package:seraph_app/src/file_browser/file_browser_controller.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/file_browser/selection_controller.dart';
import 'package:seraph_app/src/gallery/gallery_grid_controller.dart';
import 'package:seraph_app/src/gallery/gallery_image_loader.dart';
import 'package:seraph_app/src/gallery/gallery_service.dart';
import 'package:seraph_app/src/gallery/local/local_image_loader.dart';
import 'package:seraph_app/src/gallery/local/local_scan_service.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_sync_service.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_upload_backend.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_upload_service.dart';
import 'package:seraph_app/src/gallery/sync/gallery_backup_schedule_coordinator.dart';
import 'package:seraph_app/src/gallery/sync/gallery_data_sync_controller.dart';
import 'package:seraph_app/src/media_player/audio_player_controller.dart';
import 'package:seraph_app/src/search/search_service.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
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
    // Both already opened and registered in main.dart, ahead of
    // LoginController - see that file's comment for why (ticket 23's
    // cross-isolate token-refresh lock). Reused here via Get.find rather
    // than a second GalleryMirrorDatabase.open() call, which would open a
    // second, redundant connection to the same file from this same isolate.
    final galleryMirrorDatabase = Get.find<GalleryMirrorDatabase>();
    final galleryMirror = Get.find<GalleryMirror>();
    final gallerySyncService =
        Get.put(GallerySyncService(Get.find(), Get.find(), galleryMirror));
    // Local Source defaults to the platform's own (Android only, in this
    // iteration - see `local_source.dart`) - null everywhere else, which
    // makes scanning a no-op and leaves the gallery exactly as it was before
    // ticket 15 on iOS, desktop and web.
    final localScanService = Get.put(LocalScanService(galleryMirror));
    // Ticket 19: uploads one photo end to end, over the same WebDAV client
    // the file browser already uses (see WebDavGalleryUploadBackend's doc).
    // Registered unconditionally, like LocalImageLoader below - on a
    // platform with no Local Source, localScanService.localSource is null
    // and GalleryUploadService.upload simply reports deviceFileUnavailable
    // for every call, so there is nothing to gate here.
    Get.put(GalleryUploadService(
      galleryMirror,
      WebDavGalleryUploadBackend(Get.find<FileService>()),
      localScanService.localSource,
    ));
    // Ticket 22: the UI's only window onto the headless engine - reads
    // GalleryMirror.syncRunState on a timer (see the controller's own doc
    // for why that, and not a callback from the engine, is the whole
    // channel). Registered unconditionally, like GalleryUploadService above
    // - GalleryDataSyncController.isSupported is false wherever
    // createGalleryDataSyncService() is (every platform without a Local
    // Source), so there is nothing to gate here either.
    Get.put(GalleryDataSyncController(galleryMirror));
    // Ticket 24: keeps WorkManager's scheduled periodic/expedited backup
    // triggers in sync with the active Sync Pairs and the user's constraint
    // settings - see the coordinator's own doc for why "is there anything
    // to schedule" and "under what constraints" are both re-evaluated here
    // rather than assumed to stay whatever they were at app start.
    // Registered unconditionally, like GalleryDataSyncController above -
    // GalleryBackupScheduleCoordinator.isSupported is false wherever
    // createGalleryBackupScheduler() is (every platform without a Local
    // Source), so there is nothing to gate here either.
    Get.put(GalleryBackupScheduleCoordinator(
        galleryMirror, Get.find<SettingsController>()));
    Get.put(GalleryImageLoader(Get.find(), Get.find(), galleryMirrorDatabase));
    // Ticket 28: loads device-photo pixels through the same Local Source the
    // scan above uses. Null-safe on its own when localScanService.localSource
    // is null (every platform without one), so this is registered
    // unconditionally rather than only where a Local Source exists.
    Get.put(LocalImageLoader(localScanService.localSource));
    // Lazily, because it reads the mirror on creation and nothing outside
    // Gallery Mode needs it - but registered here rather than in the gallery
    // route's binding, because the grid and the full-screen viewer are two
    // routes that must share one list.
    Get.lazyPut(
      () => GalleryGridController(
        mirror: galleryMirror,
        syncService: gallerySyncService,
        localScanService: localScanService,
      ),
      fenix: true,
    );
  }

}
