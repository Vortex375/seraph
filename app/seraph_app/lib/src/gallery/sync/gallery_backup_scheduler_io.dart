import 'dart:io';

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
/// Android's own WorkManager persists the two work requests under, across
/// app restarts and reboots. Changing either `uniqueName` would orphan
/// whatever is currently scheduled under the old one rather than update it.
const String _periodicUniqueName = 'gallery-periodic-backup';
const String _periodicTaskName = 'galleryPeriodicBackup';
const String _contentTriggerUniqueName = 'gallery-content-trigger-backup';
const String _contentTriggerTaskName = 'galleryContentTriggerBackup';

/// How often the periodic catch-up task runs. WorkManager's own floor for
/// periodic work is 15 minutes; this is set far above that - unattended
/// catch-up needs to eventually finish the backlog, not poll tightly, and
/// the content-uri-triggered expedited task (below) is what gives a freshly
/// taken photo its own, much faster path. No ticket criterion names an
/// exact interval; six hours is chosen so "the historical backlog catches
/// up unattended overnight" (this ticket's own framing) comfortably happens
/// within one charge cycle without waking the device more often than a
/// backlog catch-up needs.
const Duration _periodicFrequency = Duration(hours: 6);

/// The MediaStore collection ticket 17's own in-app `ContentObserver`
/// watches (`MainActivity.kt`) - reused here as a genuine OS-level
/// WorkManager `contentUriTriggers` constraint, which is what lets the
/// content-trigger task fire even with the app process fully killed, not
/// merely backgrounded.
const String _mediaImagesUri = 'content://media/external/images/media';

/// Ticket 24's WorkManager-backed scheduler (see `gallery_backup_scheduler.dart`
/// for the two triggers this registers and why). The isolate WorkManager
/// runs [galleryBackupCallbackDispatcher] in is a cold Dart isolate with no
/// `InitialBinding` singletons - exactly the same situation ticket 22's
/// foreground-service isolate is in - so the actual sync work is delegated
/// to [runHeadlessGallerySync] (`gallery_headless_sync.dart`), the same
/// function that isolate uses, rather than this class talking to the engine
/// directly.
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
    final constraints = _buildConstraints(
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
      _periodicTaskName,
      frequency: _periodicFrequency,
      constraints: constraints,
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      backoffPolicy: BackoffPolicy.exponential,
    );

    await _registerContentTrigger(constraints);
  }

  @override
  Future<void> cancelAll() async {
    _ensureInitialized();
    await Workmanager().cancelByUniqueName(_periodicUniqueName);
    await Workmanager().cancelByUniqueName(_contentTriggerUniqueName);
  }
}

Constraints _buildConstraints({
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
/// [baseConstraints] plus the [_mediaImagesUri] watch. Split out from
/// [_AndroidGalleryBackupScheduler.reschedule] because
/// [galleryBackupCallbackDispatcher] also calls this on its own, every time
/// the content-trigger task fires, to re-arm it - see that function's doc.
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
  // expedited: true + OutOfQuotaPolicy.runAsNonExpeditedWorkRequest - "a
  // newly taken photo triggers an expedited run and starts uploading within
  // seconds" (this ticket's own criterion), falling back to ordinary
  // (still-constrained, still content-triggered) work rather than being
  // silently dropped on the rare occasion the app is out of Android's
  // expedited-job quota for the day.
  await Workmanager().registerOneOffTask(
    _contentTriggerUniqueName,
    _contentTriggerTaskName,
    constraints: constraints,
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
Future<Constraints> _currentConstraintsFromSettings() async {
  final settings = SettingsController();
  await settings.init();
  return _buildConstraints(
    requireUnmeteredNetwork: settings.backupRequireUnmeteredNetwork.value,
    requireCharging: settings.backupRequireCharging.value,
    requireBatteryNotLow: settings.backupRequireBatteryNotLow.value,
  );
}

/// WorkManager's callback-dispatcher entrypoint (registered by
/// [_AndroidGalleryBackupScheduler._ensureInitialized]) - a fresh, cold Dart
/// isolate for every invocation (WorkManager's own behaviour, not something
/// this app controls), exactly like ticket 22's foreground-service isolate.
/// Both scheduled triggers - the periodic catch-up and the content-uri-
/// triggered expedited run - land here; [taskName] is the only thing
/// distinguishing them, and the sole difference in handling is that the
/// content-trigger task must re-arm its own watch (see below).
///
/// Deliberately does NOT start ticket 22's `dataSync` foreground service:
/// this callback runs the engine directly via [runHeadlessGallerySync],
/// bounded by whatever execution window WorkManager/the OS grants this
/// invocation (an expedited job may itself be promoted to a WorkManager-
/// managed foreground service by the OS on Android 12+, with WorkManager
/// handling that promotion internally - this app never calls
/// `startForegroundService` for it, which would risk Android 12's
/// restriction on starting a NEW foreground service from the background).
/// This is what the spec means by "scheduled background work is the
/// backbone, not a long-lived foreground service": each invocation chips
/// away at the queue for as long as it is allowed to run;
/// [GallerySyncEngine.run] rebuilding its queue from the mirror on every
/// call (see that class's own doc) is what makes repeated bounded
/// invocations - rather than one marathon run - a correct way to eventually
/// drain a large backlog, and what makes "background and foreground runs do
/// not both process the same photo" hold: whichever of this callback or
/// ticket 22's foreground service happens to be running is reading the SAME
/// mirror state everything else already accounts for (an item's
/// `uploadState` is written only once an attempt completes - see
/// `GallerySyncEngine`'s own doc - so there is no shared "claimed" flag two
/// concurrent engines could race on, only the ordinary SQLite write-ahead
/// concurrency `beforeOpen` already sets up for exactly this).
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
      await runHeadlessGallerySync(db);
    } catch (_) {
      // A scheduled attempt failing must never crash the WorkManager
      // executor or be treated as this app's job to retry by hand - the
      // next periodic/content-trigger firing, or the app's own full scan,
      // is the correctness backstop, exactly as ticket 17's governing rule
      // already establishes for its own trigger-only mechanism.
    } finally {
      await db?.close();
    }

    if (taskName == _contentTriggerTaskName) {
      // Android's content-uri-trigger OneTimeWorkRequests are consumed
      // after firing once - documented WorkManager behaviour, not a bug -
      // so watching must be re-registered from inside the worker itself to
      // keep noticing future photos.
      try {
        final constraints = await _currentConstraintsFromSettings();
        await _registerContentTrigger(constraints);
      } catch (_) {
        // Worst case: the next periodic run (still scheduled and
        // unaffected by this) eventually notices the same photo instead of
        // an expedited one doing so within seconds - a latency loss, never
        // a correctness one, per ticket 17's rule.
      }
    }

    return true;
  });
}
