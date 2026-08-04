import 'dart:async';

import 'package:get/get.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/sync/gallery_backup_scheduler.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';

/// Ticket 24's glue between "what does the user want backed up, and under
/// what constraints" and "what does the OS actually have scheduled" -
/// [GalleryBackupScheduler.reschedule] itself has no opinion on whether
/// there is anything worth scheduling FOR; deciding that, and keeping it
/// current as either input changes, is this class's whole job.
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
  }) : _scheduler = scheduler ?? createGalleryBackupScheduler();

  final GalleryMirror mirror;
  final SettingsController settings;
  final GalleryBackupScheduler? _scheduler;

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
  }

  /// Re-evaluates what should be scheduled and tells [_scheduler] about it -
  /// called once at startup ([onInit]), and again by every call site that
  /// can change either input: after a Sync Pair is created, removed or
  /// retargeted (`gallery_source_folders_view.dart`), and after any of the
  /// three constraint settings changes (also there). Idempotent and safe to
  /// call repeatedly - the real scheduler re-registers rather than stacking
  /// duplicates (see its own class doc's "changing constraints takes effect
  /// without reconfiguring the Sync Pair").
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
}
