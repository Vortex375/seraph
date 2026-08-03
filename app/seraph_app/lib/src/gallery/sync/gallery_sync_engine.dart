import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_upload_service.dart';

/// How [GallerySyncEngine.run] ended.
enum GallerySyncOutcome {
  /// The queue [run] built was empty - nothing to do. [SyncRunState] is
  /// still written (as [syncStatusCompleted]) so the UI reads "backup up to
  /// date" rather than nothing at all.
  nothingToDo,

  /// Every queued item was attempted (successfully or not - see
  /// [GallerySyncEngineResult.failed]).
  completed,

  /// [GallerySyncEngine.requestPause] was called before the queue drained.
  /// Calling [run] again resumes: it rebuilds the queue from the mirror,
  /// which naturally excludes whatever the paused run already finished (see
  /// [GalleryMirror.itemsPendingUpload]'s doc).
  paused,
}

/// What one [GallerySyncEngine.run] call did - the return value a caller
/// (currently only the headless isolate's own bootstrap, `gallery_data_sync_service_io.dart`)
/// can act on directly, distinct from [SyncRunState], which is for a reader
/// with no access to this same [run] call's return value (the UI, in another
/// isolate entirely).
class GallerySyncEngineResult {
  const GallerySyncEngineResult({
    required this.outcome,
    required this.uploaded,
    required this.failed,
  });

  final GallerySyncOutcome outcome;

  /// How many items [run] attempted without an exception - this counts every
  /// [GalleryUploadResult], not only [GalleryUploadResult.uploaded]/
  /// [GalleryUploadResult.alreadyPresent]: an item skipped for a reason that
  /// is not this engine's job to police (no Sync Pair, device file gone) is
  /// still "attempted", not "failed".
  final int uploaded;

  /// How many items threw rather than completing.
  final int failed;
}

/// The headless sync engine (ticket 22): works through every Device only
/// photo eligible for upload, plus every item ticket 20 left needing a
/// mismatch retry, driving [GalleryUploadService] - wiring that mechanism to
/// actually run automatically is explicitly this ticket's job (ticket 20's
/// own report: "the retry mechanism exists and is tested but nothing calls
/// it automatically yet").
///
/// **No UI dependencies of any kind** - no GetX, no `BuildContext`, nothing
/// from `package:flutter`. This is what "the engine is headless by
/// construction" (the spec, D11) means concretely: this class is
/// constructible and runnable from a plain `main()`, which is exactly what
/// the Android foreground-service isolate's bootstrap
/// (`gallery_data_sync_service_io.dart`) does, and exactly what this
/// ticket's own mirror-seam test does - the same class, unmodified, driven
/// from a test's `main()` instead of the real one.
///
/// **The local database is this engine's only output.** [run] never calls
/// back into anything resembling a UI callback; every observable effect of
/// running is a row in [GalleryMirrorDatabase] - [SyncRunState] for
/// progress, [GalleryItems] for the uploads themselves (via
/// [GalleryUploadService]/[GalleryMirror.recordUploaded]). A caller that
/// wants to show progress reads [GalleryMirror.syncRunState] independently -
/// see [GalleryDataSyncController] (`gallery_data_sync_controller.dart`) -
/// which is what makes "the UI reflects engine state by observing the local
/// database, not by being called by the engine" true rather than merely
/// stated.
///
/// **Concurrency and pausing.** Up to [concurrency] uploads run side by
/// side (the spec's "3-4 parallel uploads, tunable" - default 3, since
/// mobile radios hide latency more than they gain from more parallel
/// streams beyond that). [requestPause] is checked between items, never
/// mid-upload - "pausing takes effect promptly" is satisfied at the
/// granularity of "finishes what it already started, picks up nothing new",
/// which for a single photo PUT is a matter of seconds, not the whole
/// remaining queue.
///
/// **Deliberately not doing:** the spec's two priority classes (ticket 25),
/// the visible failure list (ticket 25), transient-vs-permanent failure
/// classification and backoff (ticket 25), and anything about when a run
/// starts unattended (ticket 24, which needs ticket 23's cross-isolate token
/// lock first). This engine only works through whatever
/// [GalleryMirror.itemsPendingUpload]/[GalleryMirror.itemsNeedingUploadRetry]
/// currently report, once, when told to.
class GallerySyncEngine {
  GallerySyncEngine(
    this.mirror,
    this.uploadService, {
    this.concurrency = 3,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final GalleryMirror mirror;
  final GalleryUploadService uploadService;

  /// How many uploads [run] drives side by side. The spec's "3-4 parallel
  /// uploads, tunable" - kept a plain constructor parameter (not itself a
  /// user setting yet) since no ticket in this phase asks for a UI to change
  /// it.
  final int concurrency;

  /// Ticket 30's clock-seam convention, reused here for the same reason:
  /// everything [run] writes to [SyncRunState.updatedAt] reads this instead
  /// of calling [DateTime.now] directly, so a test can assert on it without
  /// the value simply being "whenever the test happened to run".
  final DateTime Function() _now;

  bool _pauseRequested = false;

  /// Asks the current (or next) [run] to stop picking up new items, as soon
  /// as whatever each worker already started finishes. Idempotent, and safe
  /// to call from outside [run]'s own isolate boundary is NOT assumed here -
  /// see `gallery_data_sync_service_io.dart` for how the real headless
  /// isolate wires a cross-isolate pause request to this (a same-isolate
  /// method call, driven by the task handler's own `onReceiveData`).
  void requestPause() => _pauseRequested = true;

  /// Works through every item [GalleryMirror.itemsNeedingUploadRetry] and
  /// [GalleryMirror.itemsPendingUpload] currently report, up to
  /// [concurrency] at a time, writing progress to [GalleryMirror.
  /// writeSyncRunState] as it goes.
  ///
  /// Retries run first, ahead of the fresh backlog - a small set in
  /// practice, and fixing an already-attempted item is a more useful use of
  /// the first few seconds of a run than starting a new one.
  ///
  /// Clears its own pause flag at the start, so a caller that paused a
  /// previous run and now calls [run] again gets a real run, not one that
  /// immediately reports [GallerySyncOutcome.paused] having done nothing.
  Future<GallerySyncEngineResult> run() async {
    _pauseRequested = false;

    final retryItems = await mirror.itemsNeedingUploadRetry();
    final pendingItems = await mirror.itemsPendingUpload();
    final retryIds = retryItems.map((item) => item.id).toSet();

    final queue = Queue<GalleryItem>()
      ..addAll(retryItems)
      ..addAll(pendingItems);

    final totalItems = queue.length;
    final totalBytes = queue.fold<int>(
        0, (sum, item) => sum + _approximateBytes(item));

    if (totalItems == 0) {
      await mirror.writeSyncRunState(
        status: syncStatusCompleted,
        totalItems: 0,
        completedItems: 0,
        failedItems: 0,
        totalBytes: 0,
        completedBytes: 0,
        lastError: null,
        updatedAtMillis: _now().millisecondsSinceEpoch,
      );
      return const GallerySyncEngineResult(
        outcome: GallerySyncOutcome.nothingToDo,
        uploaded: 0,
        failed: 0,
      );
    }

    await mirror.writeSyncRunState(
      status: syncStatusRunning,
      totalItems: totalItems,
      completedItems: 0,
      failedItems: 0,
      totalBytes: totalBytes,
      completedBytes: 0,
      lastError: null,
      updatedAtMillis: _now().millisecondsSinceEpoch,
    );

    var completedItems = 0;
    var completedBytes = 0;
    var failedItems = 0;
    var pausedEarly = false;
    String? lastError;

    Future<void> writeProgress() => mirror.writeSyncRunState(
          status: syncStatusRunning,
          totalItems: totalItems,
          completedItems: completedItems,
          failedItems: failedItems,
          totalBytes: totalBytes,
          completedBytes: completedBytes,
          lastError: lastError,
          updatedAtMillis: _now().millisecondsSinceEpoch,
        );

    Future<void> worker() async {
      while (true) {
        if (_pauseRequested) {
          pausedEarly = true;
          return;
        }
        if (queue.isEmpty) {
          return;
        }
        final item = queue.removeFirst();
        final isRetry = retryIds.contains(item.id);
        try {
          final result = isRetry
              ? await uploadService.retryMismatchedUpload(item)
              : await uploadService.upload(item);
          completedItems++;
          if (_movedBytes(result)) {
            completedBytes += _approximateBytes(item);
          }
        } catch (e) {
          failedItems++;
          lastError = '$e';
        }
        await writeProgress();
      }
    }

    final workerCount = min(concurrency, queue.length);
    await Future.wait(List.generate(workerCount, (_) => worker()));

    final finalStatus = pausedEarly ? syncStatusPaused : syncStatusCompleted;
    await mirror.writeSyncRunState(
      status: finalStatus,
      totalItems: totalItems,
      completedItems: completedItems,
      failedItems: failedItems,
      totalBytes: totalBytes,
      completedBytes: completedBytes,
      lastError: lastError,
      updatedAtMillis: _now().millisecondsSinceEpoch,
    );

    return GallerySyncEngineResult(
      outcome: pausedEarly ? GallerySyncOutcome.paused : GallerySyncOutcome.completed,
      uploaded: completedItems,
      failed: failedItems,
    );
  }

  /// Whether [result] represents bytes actually reaching Seraph (a real PUT)
  /// or being recognised as already there (ticket 19's same-size
  /// short-circuit) - either way, [SyncRunState.completedBytes] should move.
  /// Every other [GalleryUploadResult] means nothing was transferred.
  bool _movedBytes(GalleryUploadResult result) =>
      result == GalleryUploadResult.uploaded ||
      result == GalleryUploadResult.alreadyPresent;

  /// [GalleryItem.localSize] when known (every row this engine ever queues
  /// has one - see [GalleryMirror.itemsPendingUpload]/[itemsNeedingUploadRetry],
  /// both scoped to `origin == 'device'` rows), falling back to [GalleryItem.
  /// size] (0 for a row that has never been through a cloud merge) rather
  /// than throwing - "roughly how much data" tolerates an approximation far
  /// better than a crash.
  int _approximateBytes(GalleryItem item) => item.localSize ?? item.size;
}
