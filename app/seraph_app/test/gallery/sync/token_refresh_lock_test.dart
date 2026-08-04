import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/sync/token_refresh_coordination.dart';

/// Ticket 23's cross-isolate token-refresh lock. Two Dart isolates never
/// share memory (the ticket's own premise), so "two isolates" here is
/// modelled the same way `gallery_mirror_database_test.dart` already models
/// an app upgrade: two INDEPENDENT [GalleryMirrorDatabase] connections
/// ([NativeDatabase], not `.memory()`) opened against the SAME file on disk.
/// That is exactly what the UI isolate and the headless sync isolate each
/// have in the real app - their own connection to one shared
/// `gallery_mirror.sqlite` - so real SQLite cross-connection locking (WAL,
/// the busy timeout, the UPSERT's own atomicity) is genuinely exercised,
/// not just drift's in-process executor queue.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GalleryMirror token refresh lock', () {
    late Directory tempDir;
    late File file;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('token_refresh_lock_test');
      file = File(p.join(tempDir.path, 'mirror.sqlite'));

      // Create the schema through ONE connection first, then close it,
      // before any test opens its own "two isolates" pair of connections
      // below. In the real app this ordering is guaranteed structurally -
      // the UI isolate always opens (and migrates) `gallery_mirror.sqlite`
      // at app start, well before the headless isolate could ever run,
      // since a Sync Pair has to be configured through the UI first. Two
      // connections BOTH racing `onCreate`'s `createAll()` against a
      // brand-new, empty file is consequently not a scenario this ticket's
      // lock needs to handle - it is schema-creation concurrency (ticket
      // 22's "the engine and the UI can both touch the database without
      // corrupting it" territory), not the token-refresh race this test
      // file is about.
      final seed = GalleryMirrorDatabase(NativeDatabase(file));
      await seed.select(seed.tokenRefreshLock).get();
      await seed.close();
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    GalleryMirrorDatabase openConnection() =>
        GalleryMirrorDatabase(NativeDatabase(file));

    test('an uncontended acquire succeeds and is reported held', () async {
      final db = openConnection();
      final mirror = GalleryMirror(db);
      addTearDown(db.close);

      final now = DateTime.now().millisecondsSinceEpoch;
      final acquired = await mirror.tryAcquireTokenRefreshLock(
        holder: 'a',
        nowMillis: now,
        leaseMillis: 30000,
      );
      expect(acquired, isTrue);
      expect(await mirror.tokenRefreshLockHeld(nowMillis: now), isTrue);
    });

    test(
        'two isolates hitting an expired token concurrently produce exactly '
        'one refresh - the loser reads the persisted token instead of '
        'refreshing again', () async {
      // Two SEPARATE connections to the same file - see this group's own
      // doc for why that, not two GalleryMirror instances sharing one
      // connection, is what actually exercises cross-isolate locking.
      final dbA = openConnection();
      final dbB = openConnection();
      addTearDown(dbA.close);
      addTearDown(dbB.close);
      final mirrorA = GalleryMirror(dbA);
      final mirrorB = GalleryMirror(dbB);

      var refreshCalls = 0;
      const persistedToken = 'refreshed-by-whichever-isolate-won';

      // Both isolates start their non-interactive refresh at (as close to)
      // the same moment - a `Completer` lets each `refresh()` callback
      // stall until BOTH have reached the point of calling it, so the test
      // does not rely on scheduling luck to create real contention.
      final bothStarted = Completer<void>();
      var startedCount = 0;
      Future<String> refresh() async {
        refreshCalls++;
        startedCount++;
        if (startedCount == 2 && !bothStarted.isCompleted) {
          bothStarted.complete();
        }
        // Only the lock's actual winner should ever reach here - give the
        // other call every chance to (wrongly) race in too, if the lock
        // were not actually serialising them.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return persistedToken;
      }

      Future<String> readPersisted() async => persistedToken;

      final results = await Future.wait<String>([
        refreshTokenWithLock<String>(
          mirror: mirrorA,
          holder: 'isolate-a',
          refresh: refresh,
          readPersisted: readPersisted,
          pollInterval: const Duration(milliseconds: 10),
        ),
        refreshTokenWithLock<String>(
          mirror: mirrorB,
          holder: 'isolate-b',
          refresh: refresh,
          readPersisted: readPersisted,
          pollInterval: const Duration(milliseconds: 10),
        ),
      ]);

      // Exactly one of the two concurrent attempts actually called the
      // (simulated) token endpoint - the other deferred to it entirely.
      expect(refreshCalls, 1);
      // Both isolates end up with the SAME, now-persisted token - the
      // loser never presented (and never even attempted) a second refresh
      // with what would have already been an invalidated grant.
      expect(results, [persistedToken, persistedToken]);
      // The lock is not left behind - the next attempt is not blocked.
      expect(
        await mirrorA.tokenRefreshLockHeld(
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        ),
        isFalse,
      );
    });

    test(
        'a refresh that fails releases the lock, and the next attempt is '
        'not blocked forever', () async {
      final db = openConnection();
      final mirror = GalleryMirror(db);
      addTearDown(db.close);

      await expectLater(
        refreshTokenWithLock<String>(
          mirror: mirror,
          holder: 'isolate-a',
          refresh: () async => throw Exception('token endpoint unreachable'),
          readPersisted: () async => 'unused',
        ),
        throwsException,
      );

      // The failed refresh's `finally` released the lock immediately - a
      // second attempt right after does not wait out the lease at all.
      final now = DateTime.now().millisecondsSinceEpoch;
      final acquired = await mirror.tryAcquireTokenRefreshLock(
        holder: 'isolate-b',
        nowMillis: now,
        leaseMillis: 30000,
      );
      expect(acquired, isTrue);
    });

    test(
        'an isolate killed while holding the lock does not deadlock the '
        'other - the lock expires and is reclaimed', () async {
      final dbA = openConnection();
      final dbB = openConnection();
      addTearDown(dbA.close);
      addTearDown(dbB.close);
      final mirrorA = GalleryMirror(dbA);
      final mirrorB = GalleryMirror(dbB);

      // Isolate A acquires the lock with a short lease and then simply
      // vanishes - no release, ever, modelling a process killed mid-refresh
      // (see [TokenRefreshLock]'s own class doc).
      final acquiredAt = DateTime.now().millisecondsSinceEpoch;
      final acquired = await mirrorA.tryAcquireTokenRefreshLock(
        holder: 'isolate-a-doomed',
        nowMillis: acquiredAt,
        leaseMillis: 100,
      );
      expect(acquired, isTrue);

      // Immediately after, isolate B cannot acquire - the lease has not
      // expired yet.
      final immediatelyAfter = await mirrorB.tryAcquireTokenRefreshLock(
        holder: 'isolate-b',
        nowMillis: DateTime.now().millisecondsSinceEpoch,
        leaseMillis: 30000,
      );
      expect(immediatelyAfter, isFalse);

      // Once the lease has actually elapsed, isolate B reclaims the lock on
      // its own - nothing from isolate A ever runs again.
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final afterExpiry = await mirrorB.tryAcquireTokenRefreshLock(
        holder: 'isolate-b',
        nowMillis: DateTime.now().millisecondsSinceEpoch,
        leaseMillis: 30000,
      );
      expect(afterExpiry, isTrue);
    });

    test(
        'refreshTokenWithLock: a caller that loses to a holder which then '
        'dies still completes, via readPersisted, once the lease expires '
        'rather than waiting the full waitTimeout', () async {
      final dbA = openConnection();
      final dbB = openConnection();
      addTearDown(dbA.close);
      addTearDown(dbB.close);
      final mirrorA = GalleryMirror(dbA);
      final mirrorB = GalleryMirror(dbB);

      // Isolate A takes the lock directly (bypassing refreshTokenWithLock)
      // and never releases it - the "killed mid-refresh" case.
      await mirrorA.tryAcquireTokenRefreshLock(
        holder: 'isolate-a-doomed',
        nowMillis: DateTime.now().millisecondsSinceEpoch,
        leaseMillis: 150,
      );

      var readCalls = 0;
      final stopwatch = Stopwatch()..start();
      final result = await refreshTokenWithLock<String>(
        mirror: mirrorB,
        holder: 'isolate-b',
        refresh: () async =>
            throw StateError('isolate B must never refresh here'),
        readPersisted: () async {
          readCalls++;
          return 'read-after-expiry';
        },
        pollInterval: const Duration(milliseconds: 20),
        waitTimeout: const Duration(seconds: 5),
      );
      stopwatch.stop();

      expect(result, 'read-after-expiry');
      expect(readCalls, 1);
      // Bounded by the doomed holder's lease (150ms) plus one poll
      // interval, not by the much larger waitTimeout - the lease expiring
      // is what actually ended the wait.
      expect(stopwatch.elapsedMilliseconds, lessThan(2000));
    });
  });
}
