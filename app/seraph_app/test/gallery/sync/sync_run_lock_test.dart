import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';

/// Ticket 24 rework (defect 2): [SyncRunLock] is what stops the
/// WorkManager-triggered path and ticket 22's foreground-service path from
/// both running [GallerySyncEngine] at once. Modelled the same way
/// `token_refresh_lock_test.dart` models "two isolates" - two INDEPENDENT
/// [GalleryMirrorDatabase] connections ([NativeDatabase], not `.memory()`)
/// opened against the SAME file on disk, so real SQLite cross-connection
/// locking is genuinely exercised, not just drift's in-process executor
/// queue. See [SyncRunLock]'s own class doc for why this is a SEPARATE
/// table from [TokenRefreshLock] rather than a repurposed row in it, even
/// though the underlying lease-based atomic-UPSERT mechanism is identical.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GalleryMirror sync-run lock', () {
    late Directory tempDir;
    late File file;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('sync_run_lock_test');
      file = File(p.join(tempDir.path, 'mirror.sqlite'));

      // Create the schema through ONE connection first - the same ordering
      // token_refresh_lock_test.dart uses, for the same reason (schema
      // creation concurrency is not what this test file is about).
      final seed = GalleryMirrorDatabase(NativeDatabase(file));
      await seed.select(seed.syncRunLock).get();
      await seed.close();
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    GalleryMirrorDatabase openConnection() =>
        GalleryMirrorDatabase(NativeDatabase(file));

    test('an uncontended acquire succeeds', () async {
      final db = openConnection();
      final mirror = GalleryMirror(db);
      addTearDown(db.close);

      final acquired = await mirror.tryAcquireSyncRunLock(
        holder: 'foreground-service',
        nowMillis: DateTime.now().millisecondsSinceEpoch,
        leaseMillis: 30000,
      );
      expect(acquired, isTrue);
    });

    test(
        'a second, different holder cannot acquire while the first holds an '
        'unexpired lease - "background and foreground runs do not both '
        'process the same photo"', () async {
      final dbA = openConnection();
      final dbB = openConnection();
      addTearDown(dbA.close);
      addTearDown(dbB.close);
      final mirrorA = GalleryMirror(dbA);
      final mirrorB = GalleryMirror(dbB);

      final now = DateTime.now().millisecondsSinceEpoch;
      final winnerAcquired = await mirrorA.tryAcquireSyncRunLock(
        holder: 'workmanager',
        nowMillis: now,
        leaseMillis: 30000,
      );
      expect(winnerAcquired, isTrue);

      final loserAcquired = await mirrorB.tryAcquireSyncRunLock(
        holder: 'foreground-service',
        nowMillis: DateTime.now().millisecondsSinceEpoch,
        leaseMillis: 30000,
      );
      expect(loserAcquired, isFalse,
          reason: 'the loser must stand down entirely, never construct a '
              'GallerySyncEngine of its own');
    });

    test(
        'the SAME holder can re-acquire (renew) its own still-valid lease - '
        'the addition SyncRunLock needs beyond TokenRefreshLock, since a '
        'sync run can legitimately span far longer than one token refresh',
        () async {
      final db = openConnection();
      final mirror = GalleryMirror(db);
      addTearDown(db.close);

      final firstNow = DateTime.now().millisecondsSinceEpoch;
      expect(
        await mirror.tryAcquireSyncRunLock(
          holder: 'workmanager',
          nowMillis: firstNow,
          leaseMillis: 500,
        ),
        isTrue,
      );

      // Renewed well before the original lease would have expired - this
      // must succeed even though the lease is still technically valid,
      // because the SAME holder is asking.
      final renewNow = firstNow + 100;
      expect(
        await mirror.tryAcquireSyncRunLock(
          holder: 'workmanager',
          nowMillis: renewNow,
          leaseMillis: 500,
        ),
        isTrue,
      );

      // A DIFFERENT holder still cannot acquire, proving the renewal
      // actually extended the lease rather than merely being permitted as a
      // side effect that left the original expiry untouched.
      expect(
        await mirror.tryAcquireSyncRunLock(
          holder: 'foreground-service',
          nowMillis: renewNow + 50,
          leaseMillis: 500,
        ),
        isFalse,
      );
    });

    test(
        'releasing frees the lock immediately for a different holder, '
        'without waiting out the lease', () async {
      final db = openConnection();
      final mirror = GalleryMirror(db);
      addTearDown(db.close);

      final now = DateTime.now().millisecondsSinceEpoch;
      await mirror.tryAcquireSyncRunLock(
        holder: 'workmanager',
        nowMillis: now,
        leaseMillis: 30000,
      );
      await mirror.releaseSyncRunLock(holder: 'workmanager');

      final acquired = await mirror.tryAcquireSyncRunLock(
        holder: 'foreground-service',
        nowMillis: DateTime.now().millisecondsSinceEpoch,
        leaseMillis: 30000,
      );
      expect(acquired, isTrue);
    });

    test('releasing with the wrong holder is a no-op - it must never clear '
        'a lock some OTHER holder has since acquired', () async {
      final db = openConnection();
      final mirror = GalleryMirror(db);
      addTearDown(db.close);

      final now = DateTime.now().millisecondsSinceEpoch;
      // "workmanager" holds a lease that has since expired and been
      // reclaimed by "foreground-service" - modelling the same race
      // TokenRefreshLock's own release doc describes.
      await mirror.tryAcquireSyncRunLock(
        holder: 'workmanager',
        nowMillis: now,
        leaseMillis: 10,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await mirror.tryAcquireSyncRunLock(
        holder: 'foreground-service',
        nowMillis: DateTime.now().millisecondsSinceEpoch,
        leaseMillis: 30000,
      );

      // The original ("workmanager") holder's late release must not touch
      // the new holder's lock.
      await mirror.releaseSyncRunLock(holder: 'workmanager');

      final stillHeldByOther = await mirror.tryAcquireSyncRunLock(
        holder: 'someone-else',
        nowMillis: DateTime.now().millisecondsSinceEpoch,
        leaseMillis: 30000,
      );
      expect(stillHeldByOther, isFalse,
          reason: '"foreground-service" must still be the holder');
    });

    test(
        'a holder killed while holding the lock does not deadlock the '
        'other - the lease expires and is reclaimed', () async {
      final dbA = openConnection();
      final dbB = openConnection();
      addTearDown(dbA.close);
      addTearDown(dbB.close);
      final mirrorA = GalleryMirror(dbA);
      final mirrorB = GalleryMirror(dbB);

      // A run acquires the lock with a short lease and then simply
      // vanishes - no release, no renewal - modelling a process killed
      // mid-run (see SyncRunLock's own class doc).
      final acquired = await mirrorA.tryAcquireSyncRunLock(
        holder: 'workmanager-doomed',
        nowMillis: DateTime.now().millisecondsSinceEpoch,
        leaseMillis: 100,
      );
      expect(acquired, isTrue);

      // Immediately after, the other path cannot acquire - the lease has
      // not expired yet.
      final immediatelyAfter = await mirrorB.tryAcquireSyncRunLock(
        holder: 'foreground-service',
        nowMillis: DateTime.now().millisecondsSinceEpoch,
        leaseMillis: 30000,
      );
      expect(immediatelyAfter, isFalse);

      // Once the lease has actually elapsed, the other path reclaims the
      // lock on its own.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final afterExpiry = await mirrorB.tryAcquireSyncRunLock(
        holder: 'foreground-service',
        nowMillis: DateTime.now().millisecondsSinceEpoch,
        leaseMillis: 30000,
      );
      expect(afterExpiry, isTrue);
    });
  });
}
