import 'gallery_backup_scheduler.dart';

/// The web build: no `dart:io`, no WorkManager, no Local Source (D7) and
/// therefore no Sync Pair a scheduled run could ever act on.
GalleryBackupScheduler? createGalleryBackupScheduler() => null;
