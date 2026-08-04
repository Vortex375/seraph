import 'gallery_backup_scheduler_unsupported.dart'
    if (dart.library.io) 'gallery_backup_scheduler_io.dart' as impl;

/// The platform's [GalleryBackupScheduler], or null where none exists.
///
/// The same conditional-import seam `local_source.dart` and
/// `gallery_data_sync_service.dart` use, for the same reason: this app ships
/// to the web too, and the real implementation needs `dart:io` (directly,
/// and through `package:workmanager`, which itself imports `dart:io`
/// unconditionally - confirmed against the package source, not assumed).
///
/// - `gallery_backup_scheduler_io.dart` (`dart.library.io`): every native
///   platform. Returns a real, WorkManager-backed scheduler on Android and
///   null everywhere else - iOS and desktop have no Local Source (D7) and
///   therefore no Sync Pair a scheduled run could ever do anything with.
/// - `gallery_backup_scheduler_unsupported.dart` (the web build): always
///   null.
GalleryBackupScheduler? createGalleryBackupScheduler() =>
    impl.createGalleryBackupScheduler();

/// Ticket 24: registers (or cancels) the OS-level triggers that run
/// [GallerySyncEngine] unattended, without the app open and without a
/// long-lived foreground service as the backbone (spec: "Scheduled
/// background work is the backbone, not a long-lived foreground service" -
/// that long-lived service, ticket 22's `dataSync` foreground service,
/// remains for the user-initiated case only).
///
/// **Three triggers, not two** - split this way specifically because
/// Android WorkManager rejects an expedited work request that also carries
/// `requiresCharging`, `requiresBatteryNotLow` or a content-URI trigger:
/// expedited jobs accept only network (and storage) constraints. Combining
/// them, as an earlier version of this scheduler did, throws at
/// registration time on any device where the user has not left every
/// constraint at its most permissive - which is not a corner case, since
/// `requireBatteryNotLow` defaults to true.
///
/// - **Periodic work** ([reschedule]) - the unattended catch-up path,
///   carrying the user's FULL constraints, on a fixed cadence regardless of
///   any trigger firing, so the historical backlog (and anything a missed
///   trigger skipped - ticket 17's governing rule, that a missed
///   notification degrades latency and never correctness, applies here too)
///   keeps making progress even if the app is never opened again after
///   configuring a Sync Pair.
/// - **Content-triggered work** ([reschedule], registered alongside the
///   periodic task) - Android's `contentUriTriggers` WorkManager constraint,
///   watching the same MediaStore images collection ticket 17's in-app
///   `ContentObserver` watches (`MainActivity.kt`), but as a genuine OS-level
///   JobScheduler trigger that fires even with the app process fully killed,
///   not merely backgrounded. **Not expedited** - it carries the user's full
///   constraints (which is what made it incompatible with `expedited` in the
///   first place), so it is subject to WorkManager's ordinary scheduling
///   latency, not "within seconds".
/// - **The fast path** ([triggerFastPath]) - a genuinely expedited one-off
///   task, carrying ONLY a network constraint (the one kind expedited work
///   accepts), fired directly by the caller in response to ticket 17's own
///   in-app content-observer stream while the app process is alive. This is
///   what actually delivers "a newly taken photo triggers an expedited run
///   and starts uploading within seconds" (this ticket's own criterion) -
///   the content-trigger task above provides the same guarantee's
///   app-closed case, at ordinary (not "within seconds") latency.
///
/// [reschedule]'s two tasks are gated on the SAME constraints -
/// [requireUnmeteredNetwork], [requireCharging], [requireBatteryNotLow] -
/// declared to WorkManager, which enforces them at the OS level before the
/// callback ever runs (spec: "constraints are declared to the OS and
/// enforced by it, not polled by us"). This is also what satisfies "with
/// constraints unmet, no upload runs and no battery is spent polling" -
/// nothing in this app ever checks these values on a timer; the OS simply
/// does not invoke the callback until they hold. [triggerFastPath] can only
/// honour the network constraint (see above); a user who requires charging
/// or a battery threshold still gets that guarantee from every OTHER photo
/// this app ever backs up - the periodic and content-trigger tasks, and any
/// user-initiated foreground batch - just not from the one-photo instant
/// path, which trades that guarantee for latency on the single item that
/// triggered it.
///
/// Idempotent and safe to call repeatedly with the same or different
/// constraint values - the real Android implementation re-registers rather
/// than stacking duplicates, which is what makes "changing constraints
/// takes effect without reconfiguring the Sync Pair" (this ticket's own
/// criterion) true: nothing about a Sync Pair's own configuration is
/// touched by a call here.
abstract class GalleryBackupScheduler {
  Future<void> reschedule({
    required bool requireUnmeteredNetwork,
    required bool requireCharging,
    required bool requireBatteryNotLow,
  });

  /// Fires (or re-fires) the expedited, network-only fast path - see this
  /// class's own doc for why it cannot carry the charging/battery
  /// constraints [reschedule]'s other two tasks do. Called by
  /// `GalleryBackupScheduleCoordinator` in direct response to ticket 17's
  /// in-app content-observer stream, debounced the same way
  /// `LocalScanService.watchForChanges` already debounces that stream for
  /// its own incremental-scan purpose.
  Future<void> triggerFastPath({required bool requireUnmeteredNetwork});

  /// Cancels every trigger - called when the last active Sync Pair is
  /// removed, so there is nothing left to schedule against and, per "no
  /// battery is spent polling", nothing keeps waking the app for no reason.
  Future<void> cancelAll();
}
