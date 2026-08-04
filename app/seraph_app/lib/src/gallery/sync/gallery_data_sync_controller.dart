import 'dart:async';

import 'package:get/get.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/sync/gallery_data_sync_service.dart';

/// The UI's window onto ticket 22's headless engine - and, deliberately, the
/// ONLY thing in the app that is: everything here reads [GalleryMirror.
/// syncRunState] on a plain timer, never anything the engine calls back into
/// this controller with (there is no such callback anywhere in this seam).
/// That is what "the UI reflects engine state by observing the local
/// database, not by being called by the engine" (this ticket's own
/// acceptance criterion) means in code, not just in the spec.
///
/// [start]/[pause] are the only two operations this controller performs
/// beyond reading - both delegate straight to [GalleryDataSyncService],
/// which on a platform with no Local Source (see [isSupported]) is null, so
/// every method here is a safe no-op there, the same "null is not a special
/// case at call sites" convention [LocalScanService] and
/// [GalleryUploadService] already follow.
class GalleryDataSyncController extends GetxController {
  GalleryDataSyncController(
    this.mirror, {
    GalleryDataSyncService? service,
    DateTime Function()? now,
    Duration pollInterval = const Duration(seconds: 1),
  })  : _service = service ?? createGalleryDataSyncService(),
        _now = now ?? DateTime.now,
        _pollInterval = pollInterval;

  final GalleryMirror mirror;
  final GalleryDataSyncService? _service;
  final DateTime Function() _now;
  final Duration _pollInterval;

  /// Whether this platform can run a backup at all - false wherever
  /// [createGalleryDataSyncService] returns null (every platform without a
  /// Local Source). The Backup section of the Gallery folders screen is
  /// omitted entirely when this is false, the same "absent rather than
  /// present and broken" rule ticket 29's device section already follows.
  bool get isSupported => _service != null;

  /// The latest [SyncRunState] snapshot - an idle, all-zero one until the
  /// first read completes.
  final Rx<SyncRunStateData> state = Rx<SyncRunStateData>(
    const SyncRunStateData(
      id: syncRunStateId,
      status: syncStatusIdle,
      totalItems: 0,
      completedItems: 0,
      failedItems: 0,
      totalBytes: 0,
      completedBytes: 0,
      lastError: null,
      updatedAt: 0,
      globalBackoffStreak: 0,
    ),
  );

  /// Ticket 25's visible failure list - [GalleryMirror.failedUploadItems],
  /// polled on the same timer as [state] so the Gallery folders screen's
  /// failure section never has to poll the mirror on its own. Empty until
  /// the first read completes, the same "no null-check needed" convention
  /// [state] itself uses.
  final RxList<GalleryItem> failedItems = RxList<GalleryItem>([]);

  Timer? _pollTimer;

  @override
  void onInit() {
    super.onInit();
    unawaited(_reconcileAndStartPolling());
  }

  @override
  void onClose() {
    _pollTimer?.cancel();
    super.onClose();
  }

  /// **The "no stuck state" reconciliation.** A [SyncRunState] row left as
  /// [syncStatusRunning] is not, by itself, proof a run is still active -
  /// the process that wrote it (an earlier app session, or the foreground
  /// service on its own) may simply have been killed before it got to write
  /// anything else. This is checked once, here, against
  /// [GalleryDataSyncService.isRunning] (the platform's own, authoritative
  /// answer): a `running` row with no service actually alive is corrected to
  /// [syncStatusPaused] - already exactly "not running, but resumable", so
  /// nothing further needs inventing for this case - before the UI ever
  /// shows it. Without this, killing the app mid-run would leave the Backup
  /// section claiming a run is in progress indefinitely.
  Future<void> _reconcileAndStartPolling() async {
    var current = await mirror.syncRunState();
    final service = _service;
    if (service != null && current.status == syncStatusRunning) {
      final actuallyRunning = await service.isRunning();
      if (!actuallyRunning) {
        await mirror.writeSyncRunState(
          status: syncStatusPaused,
          totalItems: current.totalItems,
          completedItems: current.completedItems,
          failedItems: current.failedItems,
          totalBytes: current.totalBytes,
          completedBytes: current.completedBytes,
          lastError: current.lastError,
          updatedAtMillis: _now().millisecondsSinceEpoch,
        );
        current = await mirror.syncRunState();
      }
    }
    state.value = current;
    failedItems.value = await mirror.failedUploadItems();

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) async {
      state.value = await mirror.syncRunState();
      failedItems.value = await mirror.failedUploadItems();
    });
  }

  /// Starts (or resumes) a backup run. A no-op on a platform with no Local
  /// Source.
  Future<void> start() async {
    await _service?.start();
  }

  /// Asks the running engine to pause - see [GallerySyncEngine.requestPause]
  /// for what "promptly" means here. A no-op on a platform with no Local
  /// Source, or if nothing is currently running.
  Future<void> pause() async {
    await _service?.pause();
  }

  /// The failure list's retry action (ticket 25): clears [item]'s failure
  /// bucket via [GalleryMirror.retryFailedUpload] - "requires no
  /// reconfiguration", so that alone is enough to make it an ordinary
  /// pending upload again - then starts a run immediately, the same
  /// [start] a user pressing the Backup card's own button triggers, so the
  /// retry is not left waiting for the next scheduled pass.
  Future<void> retryFailedItem(GalleryItem item) async {
    await mirror.retryFailedUpload(item.id);
    failedItems.value = await mirror.failedUploadItems();
    await start();
  }
}
