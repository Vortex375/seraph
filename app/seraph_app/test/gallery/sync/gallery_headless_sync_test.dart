import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/sync/gallery_headless_sync.dart';

/// Ticket 24 rework (defect 2): [runHeadlessGallerySync] is the ONE place
/// either headless entrypoint (ticket 22's foreground service, ticket 24's
/// WorkManager callback) can construct a `GallerySyncEngine`, and it must
/// refuse to do so at all when the other entrypoint already holds
/// [SyncRunLock] - "background and foreground runs do not both process the
/// same photo" (this ticket's own criterion).
///
/// Covered here at exactly the short-circuit: pre-acquiring the lock under
/// a DIFFERENT holder before calling [runHeadlessGallerySync] must make it
/// return [HeadlessSyncAttempt.lockBusy] immediately, without ever reaching
/// [loadHeadlessSyncSession] (which would need a real platform channel/OIDC
/// session this test deliberately never sets up) - if the short-circuit
/// were not first, this test would hang or throw instead of returning
/// quickly with `lockBusy: true`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('runHeadlessGallerySync lock-busy short-circuit', () {
    late GalleryMirrorDatabase db;
    late GalleryMirror mirror;

    setUp(() {
      db = GalleryMirrorDatabase(NativeDatabase.memory());
      mirror = GalleryMirror(db);
    });

    tearDown(() async {
      await db.close();
    });

    test(
        'returns lockBusy immediately when a different holder already holds '
        'SyncRunLock, without touching SyncRunState', () async {
      await mirror.tryAcquireSyncRunLock(
        holder: syncRunLockHolderForegroundService,
        nowMillis: DateTime.now().millisecondsSinceEpoch,
        leaseMillis: 30000,
      );

      final before = await mirror.syncRunState();

      final attempt = await runHeadlessGallerySync(
        db,
        lockHolder: syncRunLockHolderWorkManager,
      );

      expect(attempt.lockBusy, isTrue);
      expect(attempt.result, isNull);

      final after = await mirror.syncRunState();
      expect(after.status, before.status,
          reason: 'a refused attempt must never touch SyncRunState - the '
              'winner is already the one writing it');
      expect(after.lastError, before.lastError);
    });

    test('the SAME holder is never refused by its own still-valid lease - '
        'a caller retrying with its own identity is not mistaken for a '
        'concurrent competitor', () async {
      await mirror.tryAcquireSyncRunLock(
        holder: syncRunLockHolderWorkManager,
        nowMillis: DateTime.now().millisecondsSinceEpoch,
        leaseMillis: 30000,
      );

      // Confirmed via the lock primitive directly (not
      // runHeadlessGallerySync itself, which would go on to attempt a real,
      // unmocked session load past this point) - this is the same
      // self-renewal semantic runHeadlessGallerySync's own periodic renewal
      // timer relies on while an engine run is in progress.
      final reacquired = await mirror.tryAcquireSyncRunLock(
        holder: syncRunLockHolderWorkManager,
        nowMillis: DateTime.now().millisecondsSinceEpoch,
        leaseMillis: 30000,
      );
      expect(reacquired, isTrue);
    });
  });
}
