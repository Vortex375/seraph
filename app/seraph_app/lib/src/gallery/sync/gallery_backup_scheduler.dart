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
/// Two triggers, both registered by [reschedule] together, matching the
/// ticket's own framing:
///
/// - **Periodic work** - the unattended catch-up path. Runs on a fixed
///   cadence regardless of any content-observer trigger firing, so the
///   historical backlog (and anything a missed trigger skipped - ticket 17's
///   governing rule, that a missed notification degrades latency and never
///   correctness, applies here too) keeps making progress even if the app is
///   never opened again after configuring a Sync Pair.
/// - **Expedited, content-triggered work** - "a newly taken photo triggers
///   an expedited run and starts uploading within seconds" (this ticket's
///   own criterion). Backed by Android's `contentUriTriggers` WorkManager
///   constraint watching the same MediaStore images collection ticket 17's
///   in-app `ContentObserver` watches (`MainActivity.kt`) - but, unlike that
///   one, a genuine OS-level JobScheduler trigger that fires even with the
///   app process not merely backgrounded but fully killed, which is what
///   makes "photos back up with the app closed" true for the *latency*
///   criterion and not only the periodic-catch-up one.
///
/// **Both are gated on the SAME constraints** - [requireUnmeteredNetwork],
/// [requireCharging], [requireBatteryNotLow] - declared to WorkManager, which
/// enforces them at the OS level before the callback ever runs (spec:
/// "constraints are declared to the OS and enforced by it, not polled by
/// us"). This is also what satisfies "with constraints unmet, no upload runs
/// and no battery is spent polling" - nothing in this app ever checks these
/// values on a timer; the OS simply does not invoke the callback until they
/// hold.
///
/// Idempotent and safe to call repeatedly with the same or different
/// constraint values - the real Android implementation re-registers both
/// tasks with `ExistingWorkPolicy.update`/`replace` rather than stacking
/// duplicates, which is what makes "changing constraints takes effect
/// without reconfiguring the Sync Pair" (this ticket's own criterion) true:
/// nothing about a Sync Pair's own configuration is touched by a call here.
abstract class GalleryBackupScheduler {
  Future<void> reschedule({
    required bool requireUnmeteredNetwork,
    required bool requireCharging,
    required bool requireBatteryNotLow,
  });

  /// Cancels both triggers - called when the last active Sync Pair is
  /// removed, so there is nothing left to schedule against and, per "no
  /// battery is spent polling", nothing keeps waking the app for no reason.
  Future<void> cancelAll();
}
