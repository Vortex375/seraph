import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/sync/gallery_headless_sync.dart';
import 'package:seraph_app/src/gallery/sync/gallery_sync_engine.dart';

/// The headless isolate's entry point (`gallery_data_sync_service_io.dart`
/// registers this as `startService`'s `callback`). **This is what makes the
/// engine "a headless Dart isolate" rather than a figure of speech**:
/// `flutter_foreground_task` spawns a genuinely separate `FlutterEngine` for
/// Android's `dataSync` foreground service and runs this function there, with
/// no `BuildContext`, no widget tree, and none of the `Get.put`-registered
/// singletons `InitialBinding` sets up for the app's own UI isolate - every
/// dependency [_GallerySyncTaskHandler] needs, it constructs for itself
/// (via [runHeadlessGallerySync], `gallery_headless_sync.dart`), from the
/// same persisted state (secure storage, settings) the UI isolate reads on
/// its own cold start.
@pragma('vm:entry-point')
void galleryDataSyncCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(_GallerySyncTaskHandler());
}

/// A signal sent over [FlutterForegroundTask.sendDataToTask] - from
/// [GalleryDataSyncController] via the real service
/// (`gallery_data_sync_service_io.dart`) - asking the running engine to
/// pause. The paired notification button uses the same string as its id, so
/// [TaskHandler.onNotificationButtonPressed] and [TaskHandler.onReceiveData]
/// can share one handler.
const String pauseSignal = 'pause';

/// The counterpart signal, sent when [GalleryDataSyncController.start] finds
/// the service already alive (the paused-but-not-stopped case - see
/// [_GallerySyncTaskHandler._runOnce]'s doc for why a paused run leaves the
/// service running rather than stopping it) - runs [GallerySyncEngine.run]
/// again rather than restarting the whole isolate from scratch.
const String resumeSignal = 'resume';

/// Runs [GallerySyncEngine] inside the foreground service's own isolate.
///
/// **No UI dependencies reach this class** - it talks to
/// [GalleryMirrorDatabase] and [GalleryUploadBackend] alone (via
/// [runHeadlessGallerySync]), exactly like [GallerySyncEngine] itself; the
/// only `flutter_foreground_task` API it touches is updating its OWN
/// notification text and reacting to its OWN notification's button, neither
/// of which is "the UI" in the sense ticket 22's "the UI reflects engine
/// state by observing the local database, not by being called by the
/// engine" criterion means (see [GallerySyncEngine]'s own class doc) - the
/// app's actual Flutter UI ([GalleryDataSyncController]) never receives a
/// call from this isolate at all, only from independently polling
/// [GalleryMirror.syncRunState].
class _GallerySyncTaskHandler extends TaskHandler {
  GalleryMirrorDatabase? _db;
  GallerySyncEngine? _engine;
  Timer? _notificationTimer;
  bool _running = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    unawaited(_runOnce());
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_updateNotification());
  }

  @override
  void onReceiveData(Object data) {
    if (data == pauseSignal) {
      _engine?.requestPause();
    } else if (data == resumeSignal) {
      unawaited(_runOnce());
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == pauseSignal) {
      _engine?.requestPause();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _notificationTimer?.cancel();
    await _db?.close();
  }

  /// Bootstraps every dependency [GallerySyncEngine] needs from scratch (via
  /// [runHeadlessGallerySync]), runs one [GallerySyncEngine.run], updates the
  /// notification once more with the final outcome, then stops the
  /// foreground service itself - a run that finished (whether by draining
  /// the queue or by [pauseSignal]) has nothing left to do in the
  /// background, and Android discourages a foreground service that sits
  /// idle.
  ///
  /// A session that cannot be obtained (never logged in on this device, or
  /// the persisted session has expired) aborts the run with
  /// [SyncRunState.lastError] already set by [runHeadlessGallerySync],
  /// rather than the one thing this isolate must never do: fall back to an
  /// interactive login flow with no UI to show it in. See
  /// [loadHeadlessSyncSession]'s doc.
  Future<void> _runOnce() async {
    if (_running) {
      return;
    }
    _running = true;
    try {
      final db = _db ??= GalleryMirrorDatabase.open();

      _notificationTimer ??=
          Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_updateNotification());
      });

      final result = await runHeadlessGallerySync(
        db,
        onEngineReady: (engine) => _engine = engine,
      );
      await _updateNotification();

      if (result == null) {
        await FlutterForegroundTask.updateService(
          notificationTitle: 'Backup could not start',
          notificationText: 'Not signed in - open Seraph to sign in.',
        );
        await FlutterForegroundTask.stopService();
        return;
      }

      if (result.outcome != GallerySyncOutcome.paused) {
        await FlutterForegroundTask.stopService();
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _updateNotification() async {
    final db = _db;
    if (db == null) {
      return;
    }
    final state = await GalleryMirror(db).syncRunState();
    final remaining =
        (state.totalItems - state.completedItems - state.failedItems)
            .clamp(0, state.totalItems);
    final remainingMb =
        ((state.totalBytes - state.completedBytes) / (1024 * 1024))
            .clamp(0, double.infinity);
    final text = switch (state.status) {
      syncStatusRunning =>
        '$remaining photo${remaining == 1 ? '' : 's'} left '
            '(~${remainingMb.toStringAsFixed(1)} MB)',
      syncStatusCompleted => state.totalItems == 0
          ? 'Everything is backed up'
          : 'Backup complete - ${state.completedItems} photo'
              '${state.completedItems == 1 ? '' : 's'} sent',
      syncStatusPaused => 'Paused - $remaining photo'
          '${remaining == 1 ? '' : 's'} left',
      _ => 'Backing up…',
    };
    await FlutterForegroundTask.updateService(
      notificationTitle: 'Seraph backup',
      notificationText: text,
    );
  }
}
