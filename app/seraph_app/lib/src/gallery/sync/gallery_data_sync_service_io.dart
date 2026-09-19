import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:seraph_app/src/gallery/sync/gallery_data_sync_types.dart';
import 'package:seraph_app/src/gallery/sync/gallery_sync_task_handler.dart';

/// Every native platform this app ships to. Only Android gets a real
/// [GalleryDataSyncService] (D7, same reasoning `local_source_io.dart`
/// applies to [LocalSource]) - iOS and desktop fall through to null, same as
/// the web build, since there is no Local Source and therefore no Sync Pair
/// there to ever have anything queued for upload.
GalleryDataSyncService? createGalleryDataSyncService() =>
    Platform.isAndroid ? _AndroidGalleryDataSyncService() : null;

/// Drives Android's `dataSync` foreground service via
/// `flutter_foreground_task` - `startService`'s `callback` is
/// [galleryDataSyncCallback] (`gallery_sync_task_handler.dart`), which spawns
/// the actual headless isolate [GallerySyncEngine] runs in; everything past
/// that point is [_GallerySyncTaskHandler]'s job, not this class's - this
/// class only starts, pauses and stops the platform service itself.
class _AndroidGalleryDataSyncService implements GalleryDataSyncService {
  static const int _serviceId = 8420;
  static bool _initialized = false;

  void _ensureInitialized() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'seraph_gallery_backup',
        channelName: 'Photo backup',
        channelDescription:
            'Shows progress while Seraph backs up photos from this device.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(2000),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  @override
  Future<void> start() async {
    _ensureInitialized();

    final permission = await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    if (await FlutterForegroundTask.isRunningService) {
      // Already running (a resume while it never actually stopped, or a
      // second `start()` racing the first) - nudge it rather than starting
      // a second service, which the platform would refuse anyway.
      FlutterForegroundTask.sendDataToTask(resumeSignal);
      return;
    }

    await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: const [ForegroundServiceTypes.dataSync],
      notificationTitle: 'Seraph backup',
      notificationText: 'Starting…',
      // The pause button [_GallerySyncTaskHandler.onNotificationButtonPressed]
      // already handles (`gallery_sync_task_handler.dart`) - its id MUST
      // match [pauseSignal], the same string used there. Set once, here, at
      // startService: the plugin's native side (`NotificationContent.
      // updateData` in `flutter_foreground_task`) only overwrites the stored
      // button set when a later `updateService` call is itself given
      // `notificationButtons` - [_GallerySyncTaskHandler]'s own periodic
      // `updateService` calls (title/text only) never do, so this button
      // persists across every one of them without needing to be re-passed.
      notificationButtons: const [
        NotificationButton(id: pauseSignal, text: 'Pause'),
      ],
      callback: galleryDataSyncCallback,
    );
  }

  @override
  Future<void> pause() async {
    if (!await FlutterForegroundTask.isRunningService) {
      return;
    }
    FlutterForegroundTask.sendDataToTask(pauseSignal);
  }

  @override
  Future<bool> isRunning() => FlutterForegroundTask.isRunningService;
}
