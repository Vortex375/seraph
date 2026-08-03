import 'gallery_data_sync_types.dart';

/// The web build: no foreground service, no headless isolate, nothing to
/// back up - Sync Pairs are Android-only (D7).
GalleryDataSyncService? createGalleryDataSyncService() => null;
