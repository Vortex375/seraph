import 'dart:async';

import 'package:get/get.dart';
import 'package:seraph_app/src/gallery/local/local_source.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/sync/gallery_backup_scheduler.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';

/// Ticket 24's glue between "what does the user want backed up, and under
/// what constraints" and "what does the OS actually have scheduled" -
/// [GalleryBackupScheduler.reschedule]/[GalleryBackupScheduler.triggerFastPath]
/// have no opinion on whether there is anything worth scheduling FOR;
/// deciding that, and keeping it current as any input changes, is this
/// class's whole job.
///
/// Whether anything is scheduled at all is driven purely by whether at
/// least one active Sync Pair exists ([GalleryMirror.listSyncPairs]) - the
/// same signal the ticket 22 Backup card already keys its own visibility
/// off of. With none, [syncSchedule] cancels everything rather than leaving
/// a periodic task registered that would just find an empty queue on every
/// firing - not required by any single acceptance criterion, but the same
/// "no battery spent on work with nothing to do" spirit "no battery is
/// spent polling" (the constraint-unmet criterion) already states for a
/// different case.
class GalleryBackupScheduleCoordinator extends GetxController {
  GalleryBackupScheduleCoordinator(
    this.mirror,
    this.settings, {
    GalleryBackupScheduler? scheduler,
    LocalSource? localSource,
    Duration fastPathDebounce = const Duration(milliseconds: 750),
  })  : _scheduler = scheduler ?? createGalleryBackupScheduler(),
        _localSource = localSource,
        _fastPathDebounce = fastPathDebounce;

  final GalleryMirror mirror;
  final SettingsController settings;
  final GalleryBackupScheduler? _scheduler;

  /// The SAME [LocalSource] instance `LocalScanService` already owns
  /// (`InitialBinding` passes `localScanService.localSource` in) - never a
  /// second, independently-constructed one: [AndroidLocalSource]'s own class
  /// doc explains why a second instance would steal the platform channel's
  /// single native-to-Dart handler slot out from under the first. `null`
  /// wherever [LocalScanService.localSource] itself is (every platform
  /// without a Local Source), which makes [_watchForFastPathTriggers] a
  /// no-op there, the same convention every other Gallery Mode Android-only
  /// seam follows.
  final LocalSource? _localSource;

  /// How long [_watchForFastPathTriggers] waits after a trigger before
  /// actually calling [GalleryBackupScheduler.triggerFastPath] - the same
  /// "coalesce a burst into one" reasoning [LocalScanService]'s own debounce
  /// documents, reused here at the same default duration so a burst of
  /// content-observer notifications produces one fast-path registration,
  /// not one per photo. Overridable for tests.
  final Duration _fastPathDebounce;

  StreamSubscription<void>? _fastPathSubscription;
  Timer? _fastPathDebounceTimer;

  /// Whether this platform can schedule background backup at all - false
  /// wherever [createGalleryBackupScheduler] returns null (every platform
  /// without a Local Source). [syncSchedule] is a no-op there, the same
  /// "null is not a special case at call sites" convention every other
  /// Gallery Mode Android-only seam already follows.
  bool get isSupported => _scheduler != null;

  @override
  void onInit() {
    super.onInit();
    unawaited(syncSchedule());
    _watchForFastPathTriggers();
  }

  @override
  void onClose() {
    _fastPathDebounceTimer?.cancel();
    unawaited(_fastPathSubscription?.cancel());
    super.onClose();
  }

  /// Re-evaluates what should be scheduled and tells [_scheduler] about it -
  /// called once at startup ([onInit]), and again by every call site that
  /// can change either input: after a Sync Pair is created, removed or
  /// retargeted (`gallery_source_folders_view.dart`), and after any of the
  /// three constraint settings changes (also there). Idempotent and safe to
  /// call repeatedly - the real scheduler re-registers rather than stacking
  /// duplicates (see its own class doc's "changing constraints takes effect
  /// without reconfiguring the Sync Pair").
  ///
  /// Governs only the periodic and content-trigger tasks
  /// ([GalleryBackupScheduler.reschedule]/`cancelAll`) - the fast path
  /// ([GalleryBackupScheduler.triggerFastPath]) is event-driven, fired by
  /// [_watchForFastPathTriggers] instead, and re-checks whether there is
  /// anything to back up to at the moment it fires rather than only here.
  Future<void> syncSchedule() async {
    final scheduler = _scheduler;
    if (scheduler == null) {
      return;
    }
    final pairs = await mirror.listSyncPairs();
    if (pairs.isEmpty) {
      await scheduler.cancelAll();
      return;
    }
    await scheduler.reschedule(
      requireUnmeteredNetwork: settings.backupRequireUnmeteredNetwork.value,
      requireCharging: settings.backupRequireCharging.value,
      requireBatteryNotLow: settings.backupRequireBatteryNotLow.value,
    );
  }

  /// Ticket 24 rework: subscribes directly to ticket 17's in-app
  /// content-observer stream ([_localSource]'s `changes`) so a freshly taken
  /// photo fires [GalleryBackupScheduler.triggerFastPath] - the genuinely
  /// expedited, seconds-latency path - independent of whether the gallery
  /// screen happens to be open (`LocalScanService.watchForChanges`'s own
  /// subscription is scoped to `GalleryGridController`'s lifecycle; this one
  /// is scoped to the app's, via this controller's own `Get.put(permanent:
  /// true)`-style registration in `InitialBinding`).
  ///
  /// A no-op wherever [_scheduler] or [_localSource] is null.
  void _watchForFastPathTriggers() {
    final scheduler = _scheduler;
    final source = _localSource;
    if (scheduler == null || source == null) {
      return;
    }
    _fastPathSubscription = source.changes.listen((_) {
      _fastPathDebounceTimer?.cancel();
      _fastPathDebounceTimer = Timer(_fastPathDebounce, () {
        unawaited(_fireFastPath(scheduler));
      });
    });
  }

  /// Fires the fast path, but only if there is currently something it could
  /// possibly back up to - re-checked here (not just once at startup)
  /// because a content-observer trigger can arrive at any time, including
  /// after the last Sync Pair was removed. Firing an expedited WorkManager
  /// task with nothing for it to do would just wake the device for no
  /// reason - exactly what [syncSchedule]'s own "no battery is spent
  /// polling" reasoning already rules out for the other two tasks.
  Future<void> _fireFastPath(GalleryBackupScheduler scheduler) async {
    final pairs = await mirror.listSyncPairs();
    if (pairs.isEmpty) {
      return;
    }
    await scheduler.triggerFastPath(
      requireUnmeteredNetwork: settings.backupRequireUnmeteredNetwork.value,
    );
  }
}
