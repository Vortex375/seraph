import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/sync/gallery_backup_schedule_coordinator.dart';
import 'package:seraph_app/src/gallery/sync/gallery_backup_scheduler.dart';

import '../gallery_test_support.dart';

/// Records every call it receives rather than talking to any platform -
/// ticket 24's own coverage requirement: "scheduling registration itself is
/// verified by inspection of what is scheduled, not by waiting on the OS".
/// [GalleryBackupScheduleCoordinator] is the only thing under test here; the
/// real WorkManager-backed implementation (`gallery_backup_scheduler_io.dart`)
/// is Android-only platform glue with nothing left to unit test once this
/// class's decisions are covered - see that file's own doc.
class FakeGalleryBackupScheduler implements GalleryBackupScheduler {
  final List<
      ({
        bool requireUnmeteredNetwork,
        bool requireCharging,
        bool requireBatteryNotLow
      })> rescheduleCalls = [];
  final List<bool> fastPathCalls = [];
  int cancelAllCalls = 0;

  @override
  Future<void> reschedule({
    required bool requireUnmeteredNetwork,
    required bool requireCharging,
    required bool requireBatteryNotLow,
  }) async {
    rescheduleCalls.add((
      requireUnmeteredNetwork: requireUnmeteredNetwork,
      requireCharging: requireCharging,
      requireBatteryNotLow: requireBatteryNotLow,
    ));
  }

  @override
  Future<void> triggerFastPath({required bool requireUnmeteredNetwork}) async {
    fastPathCalls.add(requireUnmeteredNetwork);
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GalleryBackupScheduleCoordinator.syncSchedule', () {
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;
    late FakeSettingsController settings;
    late FakeGalleryBackupScheduler scheduler;

    setUp(() {
      db = GalleryMirrorDatabase(NativeDatabase.memory());
      mirror = GalleryMirror(db);
      settings = FakeSettingsController();
      scheduler = FakeGalleryBackupScheduler();
    });

    tearDown(() async {
      await db.close();
    });

    test('with no active Sync Pair, cancels everything and never registers '
        'anything - nothing to back up means nothing worth the OS waking '
        'this app for', () async {
      final coordinator =
          GalleryBackupScheduleCoordinator(mirror, settings, scheduler: scheduler);

      await coordinator.syncSchedule();

      expect(scheduler.cancelAllCalls, 1);
      expect(scheduler.rescheduleCalls, isEmpty);
    });

    test('with an active Sync Pair, reschedules using the current constraint '
        'settings', () async {
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
      settings.setBackupRequireUnmeteredNetwork(true);
      settings.setBackupRequireCharging(true);
      settings.setBackupRequireBatteryNotLow(false);

      final coordinator =
          GalleryBackupScheduleCoordinator(mirror, settings, scheduler: scheduler);
      await coordinator.syncSchedule();

      expect(scheduler.cancelAllCalls, 0);
      expect(scheduler.rescheduleCalls, hasLength(1));
      final call = scheduler.rescheduleCalls.single;
      expect(call.requireUnmeteredNetwork, isTrue);
      expect(call.requireCharging, isTrue);
      expect(call.requireBatteryNotLow, isFalse);
    });

    test('removing the only Sync Pair moves a later syncSchedule() call from '
        'reschedule to cancelAll - "no battery spent" once there is nothing '
        'left to schedule for', () async {
      final pair = await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
      final coordinator =
          GalleryBackupScheduleCoordinator(mirror, settings, scheduler: scheduler);
      await coordinator.syncSchedule();
      expect(scheduler.rescheduleCalls, hasLength(1));

      await mirror.removeSyncPair(pair.id);
      await coordinator.syncSchedule();

      expect(scheduler.cancelAllCalls, 1);
      expect(scheduler.rescheduleCalls, hasLength(1),
          reason: 'no new reschedule call once nothing is active');
    });

    test('changing a constraint setting and calling syncSchedule() again '
        'takes effect without touching the Sync Pair itself - the ticket\'s '
        'own "changing constraints takes effect without reconfiguring the '
        'Sync Pair" criterion', () async {
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
      final coordinator =
          GalleryBackupScheduleCoordinator(mirror, settings, scheduler: scheduler);
      await coordinator.syncSchedule();
      expect(scheduler.rescheduleCalls.single.requireCharging, isFalse);

      settings.setBackupRequireCharging(true);
      await coordinator.syncSchedule();

      expect(scheduler.rescheduleCalls, hasLength(2));
      expect(scheduler.rescheduleCalls.last.requireCharging, isTrue);
      final pairsAfter = await mirror.listSyncPairs();
      expect(pairsAfter, hasLength(1),
          reason: 'the Sync Pair itself is untouched by a constraint change');
    });

    test('isSupported is false, and syncSchedule is a no-op, on a platform '
        'with no scheduler', () async {
      // No `scheduler:` argument - falls back to the real
      // createGalleryBackupScheduler(), which is null in this `flutter
      // test` process (not Android), the same "no Local Source, nothing
      // scheduled" case every other Gallery Mode Android-only seam has.
      final coordinator = GalleryBackupScheduleCoordinator(mirror, settings);

      expect(coordinator.isSupported, isFalse);
      // Must not throw even with an active Sync Pair present.
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
      await coordinator.syncSchedule();
    });
  });

  // Ticket 24 rework (defect 1 fix): the fast path is fired directly from
  // the Local Source's own content-observer stream, not folded into
  // reschedule()/an expedited variant of the content-trigger task (which is
  // what threw on a real device - see gallery_backup_scheduler_io.dart's own
  // doc). Covered here at the coordinator seam: does the right THING get
  // called, with the right constraint and the right gating, in response to
  // the stream - not the actual WorkManager registration itself, which is
  // platform glue with no further decision left to test once this is
  // covered (ticket 24's own "scheduling registration itself is verified by
  // inspection of what is scheduled, not by waiting on the OS").
  group('GalleryBackupScheduleCoordinator fast path', () {
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;
    late FakeSettingsController settings;
    late FakeGalleryBackupScheduler scheduler;
    late FakeLocalSource localSource;

    setUp(() {
      db = GalleryMirrorDatabase(NativeDatabase.memory());
      mirror = GalleryMirror(db);
      settings = FakeSettingsController();
      scheduler = FakeGalleryBackupScheduler();
      localSource = FakeLocalSource();
    });

    tearDown(() async {
      await db.close();
    });

    test('a Local Source change fires triggerFastPath, debounced, when a '
        'Sync Pair is active', () async {
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
      settings.setBackupRequireUnmeteredNetwork(false);
      final coordinator = GalleryBackupScheduleCoordinator(
        mirror,
        settings,
        scheduler: scheduler,
        localSource: localSource,
        fastPathDebounce: const Duration(milliseconds: 5),
      );
      // GetX only calls onInit() through its own Get.put()/Bindings
      // lifecycle, which this test deliberately bypasses (see the other
      // group's tests, which call syncSchedule() explicitly for the same
      // reason) - called directly here since it is what wires up the
      // fast-path subscription under test.
      coordinator.onInit();
      addTearDown(coordinator.onClose);
      // Let the initial syncSchedule() (periodic/content-trigger) settle so
      // this test's assertions are only about the fast path.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      scheduler.fastPathCalls.clear();

      localSource.emitChange();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(scheduler.fastPathCalls, [false],
          reason: 'the fast path still honours the user\'s network '
              'preference - the one constraint kind expedited work can '
              'carry');
    });

    test('a burst of Local Source changes coalesces into one triggerFastPath '
        'call, not one per change', () async {
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
      final coordinator = GalleryBackupScheduleCoordinator(
        mirror,
        settings,
        scheduler: scheduler,
        localSource: localSource,
        fastPathDebounce: const Duration(milliseconds: 20),
      );
      coordinator.onInit();
      addTearDown(coordinator.onClose);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      scheduler.fastPathCalls.clear();

      for (var i = 0; i < 10; i++) {
        localSource.emitChange();
      }
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(scheduler.fastPathCalls, hasLength(1));
    });

    test('a Local Source change with no active Sync Pair never fires '
        'triggerFastPath - nothing configured to back up to', () async {
      final coordinator = GalleryBackupScheduleCoordinator(
        mirror,
        settings,
        scheduler: scheduler,
        localSource: localSource,
        fastPathDebounce: const Duration(milliseconds: 5),
      );
      coordinator.onInit();
      addTearDown(coordinator.onClose);
      await Future<void>.delayed(const Duration(milliseconds: 5));

      localSource.emitChange();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(scheduler.fastPathCalls, isEmpty);
    });

    test('with no Local Source, the coordinator subscribes to nothing and '
        'never throws', () async {
      final coordinator = GalleryBackupScheduleCoordinator(
        mirror,
        settings,
        scheduler: scheduler,
        localSource: null,
      );
      await mirror.createSyncPair(
        localFolderPath: 'DCIM/Camera/',
        spaceProviderId: 'space-a',
        path: '/Photos/Phone',
      );
      await coordinator.syncSchedule();
      expect(scheduler.fastPathCalls, isEmpty);
    });
  });
}
