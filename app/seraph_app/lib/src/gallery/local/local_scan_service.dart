import 'dart:async';

import 'package:seraph_app/src/gallery/local/local_source.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';

/// Drives one full Local Source scan into the mirror - the device-side twin
/// of `GallerySyncService`, which does the same job for the cloud delta feed.
///
/// The full media-store scan is ticket 15's correctness anchor, run at app
/// start and again whenever [GalleryGridController]
/// (`gallery_grid_controller.dart`) refreshes the gallery, and it stays
/// exactly that: unconditional, periodic, never skipped. Ticket 17 adds two
/// faster paths on top, both strictly latency shortcuts that a full scan can
/// always outlive:
///
/// - [incrementalScan] - the generation-based fast path, applying only what
///   changed since the watermark [GalleryMirror.localGeneration] holds.
/// - [watchForChanges] - subscribes to the Local Source's content-observer
///   trigger and runs a debounced [incrementalScan] in response.
///
/// **Neither is ever the only thing standing between a photo and its backup
/// status.** [watchForChanges]'s callback and [incrementalScan] itself can
/// both fail silently, be suppressed entirely, or simply never run - the
/// governing rule this ticket exists to uphold is that none of that can ever
/// make the gallery wrong, only slower to catch up, because [scan] keeps
/// running regardless.
class LocalScanService {
  LocalScanService(
    this.mirror, {
    LocalSource? localSource,
    Duration debounce = const Duration(milliseconds: 750),
  })  : localSource = localSource ?? createLocalSource(),
        _debounce = debounce;

  final GalleryMirror mirror;

  /// Null on every platform without a Local Source - iOS, desktop, web, or
  /// an Android device with no photo-access grant. [scan] is then a no-op,
  /// which is exactly "the gallery behaves as it did before this ticket"
  /// (ticket 15's platform-neutrality criterion) rather than a special case
  /// callers need to branch on.
  final LocalSource? localSource;

  /// How long [watchForChanges] waits after a trigger before actually
  /// running [incrementalScan] - long enough that a burst of rapid
  /// notifications (burst-mode photography, a batch copy from another app)
  /// collapses into one scan rather than one per notification (ticket 17's
  /// "a burst of changes does not trigger a storm of scans"), short enough
  /// that "appears within seconds" still holds. Overridable for tests, which
  /// would otherwise have to wait out a debounce sized for production.
  final Duration _debounce;

  StreamSubscription<void>? _changesSubscription;
  Timer? _debounceTimer;
  void Function()? _onChanged;
  bool _scanRunning = false;
  bool _scanPending = false;

  /// Runs one full scan and applies it to the mirror. Safe to call
  /// repeatedly - a scan that finds nothing new does nothing, and a photo
  /// already known by its local identity is left alone (see
  /// [GalleryMirror.applyLocalScan]).
  ///
  /// Also primes [incrementalScan]'s watermark at the Local Source's current
  /// generation, so the fast path's very first run after this has something
  /// to be incremental about rather than replaying everything this full scan
  /// just saw. Priming is one-directional: a full scan never reads the
  /// watermark, so nothing about the incremental-scan/observer machinery -
  /// stale, wrong, or entirely absent - can affect what a full scan applies.
  Future<void> scan() async {
    final source = localSource;
    if (source == null) {
      return;
    }
    final items = await source.fullScan();
    await mirror.applyLocalScan(items);
    final generation = await source.currentGeneration();
    await mirror.primeLocalGeneration(generation);
  }

  /// Ticket 17's fast path: applies only the photos changed since
  /// [GalleryMirror.localGeneration], without ever removing a row - see
  /// [GalleryMirror.applyLocalDelta]. A photo this misses (a deletion, or a
  /// change that raced a failed native call) is caught by the next [scan],
  /// never left permanently wrong - only later than it could have been.
  ///
  /// A no-op with no Local Source.
  Future<void> incrementalScan() async {
    final source = localSource;
    if (source == null) {
      return;
    }
    final since = await mirror.localGeneration();
    final result = await source.incrementalScan(since);
    await mirror.applyLocalDelta(result.items, generation: result.generation);
  }

  /// Subscribes to the Local Source's content-observer trigger and runs a
  /// debounced [incrementalScan] in response, calling [onChanged] once the
  /// mirror has actually been updated - the caller's cue to re-read it (e.g.
  /// [GalleryGridController.reload]).
  ///
  /// A trigger that arrives while a scan from an earlier trigger is still
  /// running is not dropped: it schedules exactly one more scan once the
  /// current one finishes, so a burst's tail end is never lost, only
  /// coalesced - still just one extra scan, never one per trigger.
  ///
  /// A no-op with no Local Source. Idempotent: calling this again while
  /// already subscribed only updates [onChanged], so a caller recreated by
  /// GetX's `fenix` mechanism (see `GalleryGridController`) does not have to
  /// track whether it already subscribed.
  void watchForChanges(void Function() onChanged) {
    final source = localSource;
    if (source == null) {
      return;
    }
    _onChanged = onChanged;
    _changesSubscription ??= source.changes.listen((_) => _scheduleScan());
  }

  /// Cancels whatever [watchForChanges] set up - the subscription and any
  /// pending debounce timer - so nothing keeps the Local Source's stream
  /// alive past this point. Must be called when the caller no longer needs
  /// live updates (e.g. [GalleryGridController.onClose]) so the observer
  /// trigger is released with the app's lifecycle rather than leaking past
  /// it. Safe to call even if [watchForChanges] was never called.
  void stopWatchingForChanges() {
    _debounceTimer?.cancel();
    _debounceTimer = null;
    unawaited(_changesSubscription?.cancel());
    _changesSubscription = null;
  }

  /// Releases everything this service holds onto: [stopWatchingForChanges]'s
  /// subscription and timer, then [LocalSource.dispose] on [localSource]
  /// itself. Nothing calls this today - `initial_binding.dart` registers one
  /// [LocalScanService] for the app's entire lifetime via `Get.put`, so there
  /// is currently no point at which the app itself needs to release it - but
  /// leaving the lifecycle unstated is exactly what let [AndroidLocalSource]
  /// (`android_local_source.dart`) go this long without a way to release its
  /// method-channel handler at all. Making the release explicit here, rather
  /// than assumed from the singleton's lifetime, is what protects a future
  /// non-singleton binding - or a test constructing more than one
  /// [LocalScanService] against the same real channel - from the silent
  /// stream-death [LocalSource.dispose] documents.
  ///
  /// A no-op with no Local Source. Safe to call more than once.
  void dispose() {
    stopWatchingForChanges();
    localSource?.dispose();
  }

  void _scheduleScan() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () {
      unawaited(_runDebouncedScan());
    });
  }

  Future<void> _runDebouncedScan() async {
    if (_scanRunning) {
      _scanPending = true;
      return;
    }
    _scanRunning = true;
    try {
      await incrementalScan();
      _onChanged?.call();
    } catch (_) {
      // Same failure-isolation policy as GalleryGridController's cloud/full-
      // scan handling: a trigger-only mechanism failing must never surface
      // as an error to the caller. The mirror simply keeps whatever the last
      // successful scan produced, and the next periodic full scan remains
      // the correctness backstop regardless.
    } finally {
      _scanRunning = false;
      if (_scanPending) {
        _scanPending = false;
        unawaited(_runDebouncedScan());
      }
    }
  }

  /// The device photo-access grant right now, without prompting for it -
  /// [LocalPermissionStatus.unsupported] on a platform with no Local Source,
  /// exactly like [localSource] being null everywhere else in this class.
  Future<LocalPermissionStatus> permissionStatus() async {
    final source = localSource;
    if (source == null) {
      return LocalPermissionStatus.unsupported;
    }
    return source.permissionStatus();
  }

  /// Asks for access (or, under an existing partial grant, for more of it) -
  /// a no-op that reports [LocalPermissionStatus.unsupported] on a platform
  /// with no Local Source, so a caller never has to check for null first.
  Future<LocalPermissionStatus> requestPermission() async {
    final source = localSource;
    if (source == null) {
      return LocalPermissionStatus.unsupported;
    }
    return source.requestPermission();
  }

  /// Opens the platform's own settings screen for this app's permissions -
  /// the route from a partial grant to full access. A no-op with no Local
  /// Source.
  Future<void> openAppSettings() async {
    final source = localSource;
    if (source == null) {
      return;
    }
    await source.openAppSettings();
  }
}
