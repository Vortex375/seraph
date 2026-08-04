import 'dart:io';

import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/sync/gallery_backup_scheduler.dart';
import 'package:seraph_app/src/gallery/sync/gallery_headless_sync.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:workmanager/workmanager.dart';

/// Android only (D7, the same reasoning `local_source_io.dart` and
/// `gallery_data_sync_service_io.dart` apply) - null everywhere else, since
/// Sync Pairs, and therefore anything a scheduled run could act on, do not
/// exist on any other platform this app ships to.
GalleryBackupScheduler? createGalleryBackupScheduler() =>
    Platform.isAndroid ? _AndroidGalleryBackupScheduler() : null;

/// [Workmanager]'s registered `uniqueName`s/`taskName`s - stable identifiers
/// Android's own WorkManager persists the three work requests under, across
/// app restarts and reboots. Changing any `uniqueName` would orphan whatever
/// is currently scheduled under the old one rather than update it.
const String _periodicUniqueName = 'gallery-periodic-backup';
const String _contentTriggerUniqueName = 'gallery-content-trigger-backup';
const String _fastPathUniqueName = 'gallery-fast-path-backup';

/// `taskName`s - not just `uniqueName`s - are deliberately public (unlike
/// the `uniqueName`s above): [shouldRearmContentTrigger] is a pure function
/// of a `taskName`, and keeping it unit-testable without a live WorkManager
/// (ticket 24's own "scheduling registration itself is verified by
/// inspection... not by waiting on the OS") requires a test file in a
/// different library to be able to name these same values -
/// `gallery_backup_scheduler_io_test.dart` imports them directly rather
/// than duplicating the literal strings, so the two can never drift apart.
const String galleryPeriodicTaskName = 'galleryPeriodicBackup';
const String galleryContentTriggerTaskName = 'galleryContentTriggerBackup';
const String galleryFastPathTaskName = 'galleryFastPathBackup';

/// Ticket 24 rework (defect 3): whether [galleryBackupCallbackDispatcher]
/// should re-arm the content trigger after handling [taskName] - true for
/// the content-trigger task's own firing (it was just consumed and must be
/// re-registered to keep watching) AND for the periodic task's (a durable
/// backstop: WorkManager guarantees the periodic task keeps firing on
/// [_periodicFrequency] regardless of whether any previous content-trigger
/// re-arm attempt survived a killed or timed-out isolate - see
/// [galleryBackupCallbackDispatcher]'s own doc). Deliberately a plain
/// function, not inlined, so this decision is unit-testable without a live
/// WorkManager.
bool shouldRearmContentTrigger(String taskName) =>
    taskName == galleryContentTriggerTaskName ||
    taskName == galleryPeriodicTaskName;

/// How often the periodic catch-up task runs. WorkManager's own floor for
/// periodic work is 15 minutes; this is set far above that - unattended
/// catch-up needs to eventually finish the backlog, not poll tightly, and
/// the content-trigger and fast-path tasks (below) are what give a freshly
/// taken photo its own, much faster path. No ticket criterion names an
/// exact interval; six hours is chosen so "the historical backlog catches
/// up unattended overnight" (this ticket's own framing) comfortably happens
/// within one charge cycle without waking the device more often than a
/// backlog catch-up needs.
///
/// This periodic firing is ALSO the durable backstop for the content-trigger
/// task's own re-arming (see [galleryBackupCallbackDispatcher]'s doc) - six
/// hours is therefore also the worst-case bound on how long the content
/// trigger can stay un-rearmed if its own re-arm attempt was ever lost to a
/// killed or timed-out isolate.
const Duration _periodicFrequency = Duration(hours: 6);

/// The MediaStore collection ticket 17's own in-app `ContentObserver`
/// watches (`MainActivity.kt`) - reused here as a genuine OS-level
/// WorkManager `contentUriTriggers` constraint, which is what lets the
/// content-trigger task fire even with the app process fully killed, not
/// merely backgrounded.
const String _mediaImagesUri = 'content://media/external/images/media';

/// Ticket 24's WorkManager-backed scheduler (see `gallery_backup_scheduler.dart`
/// for the three triggers this registers and why they cannot be collapsed
/// into two). The isolate WorkManager runs [galleryBackupCallbackDispatcher]
/// in is a cold Dart isolate with no `InitialBinding` singletons - exactly
/// the same situation ticket 22's foreground-service isolate is in - so the
/// actual sync work is delegated to [runHeadlessGallerySync]
/// (`gallery_headless_sync.dart`), the same function that isolate uses,
/// rather than this class talking to the engine directly.
class _AndroidGalleryBackupScheduler implements GalleryBackupScheduler {
  static bool _initialized = false;

  static void _ensureInitialized() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    Workmanager().initialize(galleryBackupCallbackDispatcher);
  }

  @override
  Future<void> reschedule({
    required bool requireUnmeteredNetwork,
    required bool requireCharging,
    required bool requireBatteryNotLow,
  }) async {
    _ensureInitialized();
    final constraints = _buildFullConstraints(
      requireUnmeteredNetwork: requireUnmeteredNetwork,
      requireCharging: requireCharging,
      requireBatteryNotLow: requireBatteryNotLow,
    );

    // ExistingPeriodicWorkPolicy.update - not `replace` - so a periodic
    // task already scheduled when constraints change is reconfigured in
    // place, per WorkManager's own guidance (see that enum's doc comment).
    // This, not touching the Sync Pair at all, is what makes "changing
    // constraints takes effect without reconfiguring the Sync Pair" (this
    // ticket's own criterion) true.
    await Workmanager().registerPeriodicTask(
      _periodicUniqueName,
      galleryPeriodicTaskName,
      frequency: _periodicFrequency,
      constraints: constraints,
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      backoffPolicy: BackoffPolicy.exponential,
    );

    await _registerContentTrigger(constraints);
  }

  @override
  Future<void> triggerFastPath({required bool requireUnmeteredNetwork}) async {
    _ensureInitialized();
    await _registerFastPath(requireUnmeteredNetwork: requireUnmeteredNetwork);
  }

  @override
  Future<void> cancelAll() async {
    _ensureInitialized();
    await Workmanager().cancelByUniqueName(_periodicUniqueName);
    await Workmanager().cancelByUniqueName(_contentTriggerUniqueName);
    await Workmanager().cancelByUniqueName(_fastPathUniqueName);
  }
}

/// The full set of user-chosen constraints - valid on the periodic and
/// content-trigger tasks, NOT on the expedited fast-path task (see
/// `gallery_backup_scheduler.dart`'s class doc for why).
Constraints _buildFullConstraints({
  required bool requireUnmeteredNetwork,
  required bool requireCharging,
  required bool requireBatteryNotLow,
}) {
  return Constraints(
    networkType: requireUnmeteredNetwork
        ? NetworkType.unmetered
        : NetworkType.connected,
    requiresCharging: requireCharging,
    requiresBatteryNotLow: requireBatteryNotLow,
  );
}

/// Registers (or re-registers) the content-trigger one-off task with
/// [baseConstraints] plus the [_mediaImagesUri] watch. **Not expedited** -
/// combining `expedited: true` with `requiresCharging`/`requiresBatteryNotLow`
/// (both possibly true in [baseConstraints]) or with `contentUriTriggers` at
/// all throws at WorkManager's own `WorkRequest.Builder.build()` ("Expedited
/// jobs only support network and storage constraints") - confirmed against
/// WorkManager's own documented behaviour, not merely inferred: expedited
/// work rejects `requiresCharging`, `requiresBatteryNotLow`,
/// `requiresDeviceIdle` and any content-URI trigger outright. An earlier
/// version of this scheduler combined all three and threw on every device
/// where `requireBatteryNotLow` was left at its (default-on) value, so the
/// content-trigger task was never actually armed. [triggerFastPath] is the
/// ONLY task in this file that uses `expedited: true`, and it deliberately
/// carries no constraint this restriction would reject.
///
/// Split out from [_AndroidGalleryBackupScheduler.reschedule] because
/// [galleryBackupCallbackDispatcher] also calls this on its own, every time
/// EITHER the content-trigger or the periodic task fires, to re-arm it - see
/// that function's doc for why both, not just the content-trigger task
/// itself, re-arm it.
Future<void> _registerContentTrigger(Constraints baseConstraints) async {
  final constraints = Constraints(
    networkType: baseConstraints.networkType,
    requiresCharging: baseConstraints.requiresCharging,
    requiresBatteryNotLow: baseConstraints.requiresBatteryNotLow,
    contentUriTriggers: [
      ContentUriTrigger(
        uri: _mediaImagesUri,
        triggerForDescendants: true,
      ),
    ],
  );
  await Workmanager().registerOneOffTask(
    _contentTriggerUniqueName,
    galleryContentTriggerTaskName,
    constraints: constraints,
    existingWorkPolicy: ExistingWorkPolicy.replace,
  );
}

/// Registers the genuinely expedited fast-path one-off task - network
/// constraint only, per [_registerContentTrigger]'s doc on what expedited
/// work is allowed to carry. `runAsNonExpeditedWorkRequest` falls back to
/// ordinary (still network-constrained) work rather than being silently
/// dropped on the rare occasion the app is out of Android's expedited-job
/// quota for the day - still faster than waiting for the six-hour periodic
/// task, just not "within seconds" that one time.
Future<void> _registerFastPath({required bool requireUnmeteredNetwork}) async {
  await Workmanager().registerOneOffTask(
    _fastPathUniqueName,
    galleryFastPathTaskName,
    constraints: Constraints(
      networkType: requireUnmeteredNetwork
          ? NetworkType.unmetered
          : NetworkType.connected,
    ),
    existingWorkPolicy: ExistingWorkPolicy.replace,
    expedited: true,
    outOfQuotaPolicy: OutOfQuotaPolicy.runAsNonExpeditedWorkRequest,
  );
}

/// Reads the three constraint settings fresh from disk - the same "read the
/// same GetStorage box from a cold isolate" pattern
/// [loadHeadlessSyncSession] already uses for the server URL and OIDC
/// settings - so [galleryBackupCallbackDispatcher] can re-arm the content
/// trigger with whatever the user most recently chose, without this cold
/// isolate needing any of the UI isolate's in-memory state.
Future<Constraints> _currentFullConstraintsFromSettings() async {
  final settings = SettingsController();
  await settings.init();
  return _buildFullConstraints(
    requireUnmeteredNetwork: settings.backupRequireUnmeteredNetwork.value,
    requireCharging: settings.backupRequireCharging.value,
    requireBatteryNotLow: settings.backupRequireBatteryNotLow.value,
  );
}

/// Writes [message] to [SyncRunState.lastError] without disturbing any other
/// field - the channel the foreman directed scheduling failures to use
/// rather than a bare `catch (_)` that leaves them unobservable. Read-modify
/// -write against whatever is already there (a scheduling failure is not
/// itself a run outcome, so it must not fabricate a `status` or clobber
/// [SyncRunState.totalItems]/etc a real run already wrote). Best-effort:
/// if even this fails, there is nothing further this callback can do about
/// it.
Future<void> _recordSchedulingError(
    GalleryMirrorDatabase db, String message) async {
  try {
    final mirror = GalleryMirror(db);
    final current = await mirror.syncRunState();
    await mirror.writeSyncRunState(
      status: current.status,
      totalItems: current.totalItems,
      completedItems: current.completedItems,
      failedItems: current.failedItems,
      totalBytes: current.totalBytes,
      completedBytes: current.completedBytes,
      lastError: message,
      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
  } catch (_) {
    // Nothing further to do - see this function's own doc.
  }
}

/// WorkManager's callback-dispatcher entrypoint (registered by
/// [_AndroidGalleryBackupScheduler._ensureInitialized]) - a fresh, cold Dart
/// isolate for every invocation (WorkManager's own behaviour, not something
/// this app controls), exactly like ticket 22's foreground-service isolate.
/// All three scheduled triggers land here; [taskName] distinguishes them.
///
/// Deliberately does NOT start ticket 22's `dataSync` foreground service:
/// this callback runs the engine directly via [runHeadlessGallerySync]
/// (which also guards against overlapping ticket 22's own foreground run -
/// see that function's own doc on [SyncRunLock]), bounded by whatever
/// execution window WorkManager/the OS grants this invocation (an expedited
/// job may itself be promoted to a WorkManager-managed foreground service by
/// the OS on Android 12+, with WorkManager handling that promotion
/// internally - this app never calls `startForegroundService` for it, which
/// would risk Android 12's restriction on starting a NEW foreground service
/// from the background). This is what the spec means by "scheduled
/// background work is the backbone, not a long-lived foreground service":
/// each invocation chips away at the queue for as long as it is allowed to
/// run; [GallerySyncEngine.run] rebuilding its queue from the mirror on
/// every call (see that class's own doc) is what makes repeated bounded
/// invocations - rather than one marathon run - a correct way to eventually
/// drain a large backlog.
///
/// **Re-arming the content trigger, from TWO places, on purpose (ticket 24
/// rework, defect 3):** Android consumes a content-URI-triggered
/// `OneTimeWorkRequest` after it fires once, so watching has to be
/// re-registered every time. Doing that only from the content-trigger task's
/// own firing is not durable - if THIS isolate is killed or times out before
/// re-arming runs, the trigger is gone for good until the user next opens
/// the app. So the periodic task - which WorkManager itself guarantees keeps
/// firing every [_periodicFrequency], independent of whether any previous
/// content-trigger firing survived to re-arm itself - ALSO re-arms it, every
/// time. This makes the periodic task a self-healing backstop: even in the
/// worst case where every content-trigger re-arm attempt is lost, the
/// trigger is never un-armed for longer than one periodic interval.
///
/// A device reboot needs no extra handling here: WorkManager persists both
/// registrations itself and re-arms them after boot without this app doing
/// anything (its own manifest-merged boot receiver) - "a device rebooted
/// mid-backlog resumes without user intervention" (this ticket's own
/// criterion) falls out of that plus [GallerySyncEngine.run] always
/// resuming from the mirror's current state, never from anything this
/// callback would otherwise have to remember itself.
@pragma('vm:entry-point')
void galleryBackupCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    GalleryMirrorDatabase? db;
    try {
      db = GalleryMirrorDatabase.open();
      await runHeadlessGallerySync(db, lockHolder: syncRunLockHolderWorkManager);
    } catch (e) {
      // A scheduled attempt failing must never crash the WorkManager
      // executor or be treated as this app's job to retry by hand - the
      // next periodic/content-trigger firing, or the app's own full scan,
      // is the correctness backstop, exactly as ticket 17's governing rule
      // already establishes for its own trigger-only mechanism. Recorded
      // (not swallowed) so it is at least visible via SyncRunState.lastError.
      if (db != null) {
        await _recordSchedulingError(db, 'Scheduled backup attempt failed: $e');
      }
    }

    if (shouldRearmContentTrigger(taskName)) {
      // See this function's own doc on why both task kinds re-arm the
      // content trigger, not just the content-trigger task itself.
      try {
        final constraints = await _currentFullConstraintsFromSettings();
        await _registerContentTrigger(constraints);
      } catch (e) {
        if (db != null) {
          await _recordSchedulingError(
              db, 'Could not re-arm instant photo detection: $e');
        }
        // Worst case: the next periodic run (still scheduled and
        // unaffected by this) tries again, and a full/incremental scan
        // eventually notices the same photo regardless - a latency loss,
        // never a correctness one, per ticket 17's rule.
      }
    }

    await db?.close();
    return true;
  });
}
