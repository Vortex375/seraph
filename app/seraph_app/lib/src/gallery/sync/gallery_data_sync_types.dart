/// The platform's driver for a user-initiated backup run - starts, pauses,
/// resumes and stops [GallerySyncEngine] (`gallery_sync_engine.dart`)
/// running headlessly, surviving the app being backgrounded and the screen
/// going off.
///
/// Kept in its own file (rather than alongside [createGalleryDataSyncService]
/// in `gallery_data_sync_service.dart`) so the conditional-import
/// implementations (`gallery_data_sync_service_io.dart`,
/// `gallery_data_sync_service_unsupported.dart`) can both depend on this
/// type without importing each other - the same shape
/// `local_media_item.dart`/`local_source.dart` already use for [LocalSource].
///
/// On Android, a real implementation drives a foreground service (the
/// `dataSync` type) with its own headless Dart isolate - see
/// `gallery_data_sync_service_io.dart`. Everywhere else, [createGalleryDataSyncService]
/// (`gallery_data_sync_service.dart`) returns null: Sync Pairs, and
/// therefore anything to back up, are Android-only (D7 in the design
/// notes), so there is nothing for a backup run to do on those platforms.
abstract class GalleryDataSyncService {
  /// Starts (or, if paused, resumes) a backup run. Returns once the run has
  /// been handed off to the platform - not once the run itself finishes,
  /// which on Android can be hours.
  Future<void> start();

  /// Asks the current run to stop picking up new items, as soon as whatever
  /// is already in flight finishes - [GallerySyncEngine.requestPause]'s own
  /// "promptly" guarantee, carried across the isolate boundary.
  Future<void> pause();

  /// Whether the platform reports the backup service as currently alive.
  /// Read by [GalleryDataSyncController]'s startup reconciliation to tell a
  /// genuinely still-running service apart from a `running` [SyncRunState]
  /// row a killed process simply never got to correct.
  Future<bool> isRunning();
}
