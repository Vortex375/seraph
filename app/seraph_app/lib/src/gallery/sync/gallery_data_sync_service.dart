import 'gallery_data_sync_service_unsupported.dart'
    if (dart.library.io) 'gallery_data_sync_service_io.dart' as impl;
import 'gallery_data_sync_types.dart';

export 'gallery_data_sync_types.dart';

/// The platform's [GalleryDataSyncService], or null where none exists.
///
/// The same conditional-import seam `local_source.dart` uses, for the same
/// reason: this app ships to the web too (served as Seraph's own web UI),
/// and `dart:io` - which the real Android implementation needs, both
/// directly and through `flutter_foreground_task` - does not exist there.
///
/// - `gallery_data_sync_service_io.dart` (`dart.library.io`): every native
///   platform. Returns a real, `flutter_foreground_task`-backed service on
///   Android and null everywhere else - iOS and desktop have no Local
///   Source (D7) and therefore nothing a Sync Pair could ever cover, so
///   there is nothing for a backup run to do there either.
/// - `gallery_data_sync_service_unsupported.dart` (the web build): always
///   null.
///
/// Null is not a failure case to special-case at call sites -
/// [GalleryDataSyncController] (`gallery_data_sync_controller.dart`) treats
/// it exactly like [LocalScanService] treats a null [LocalSource]: the
/// backup UI simply does not offer anything a null service could not do.
GalleryDataSyncService? createGalleryDataSyncService() =>
    impl.createGalleryDataSyncService();
