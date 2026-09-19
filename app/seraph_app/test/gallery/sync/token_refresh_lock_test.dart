import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oidc/oidc.dart';
import 'package:path/path.dart' as p;
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/sync/token_refresh_coordination.dart';

/// Base64url-encodes [value] the JWT way: no `=` padding (`dart:convert`'s
/// `base64Url` codec pads by default; `decodeBase64EncodedBytes` on the
/// `jose_plus` decode side re-adds it, but the encode side must strip it to
/// look like a real token).
String _b64(Object value) =>
    base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');

/// Builds a syntactically-valid but unsigned (`alg: none`) id_token JWT -
/// enough for [OidcUser.fromIdToken] to parse with no `keystore` (the
/// unverified path every call site in this app already uses for a manager
/// it never asked to verify signatures itself), without any real OIDC
/// provider to sign a real one against.
String _fakeIdToken({required String sub}) {
  final header = _b64({'alg': 'none', 'typ': 'JWT'});
  final payload = _b64({
    'sub': sub,
    'iss': 'https://example.test',
    'aud': 'test-client',
    'iat': 0,
    'exp': 9999999999,
  });
  return '$header.$payload.';
}

/// Builds an [OidcUser] carrying [refreshToken] as its current refresh
/// token - standing in for "whatever a real token endpoint handed back",
/// since this test never talks to one. [sub] varies the id_token subject so
/// two users built by this helper are trivially distinguishable if needed.
Future<OidcUser> _buildTestUser({
  required String refreshToken,
  String sub = 'user-1',
}) {
  return OidcUser.fromIdToken(
    token: OidcToken(
      creationTime: DateTime.now(),
      accessToken: 'access-for-$refreshToken',
      refreshToken: refreshToken,
      idToken: _fakeIdToken(sub: sub),
      expiresIn: const Duration(hours: 1),
    ),
  );
}

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

  group('LockedOidcUserManager.adoptPersistedUser', () {
    LockedOidcUserManager buildManager() => LockedOidcUserManager.lazy(
          discoveryDocumentUri:
              Uri.parse('https://example.test/.well-known/openid-configuration'),
          clientCredentials: OidcClientAuthentication.none(
            clientId: 'test-client',
          ),
          store: OidcMemoryStore(),
          settings: lockedOidcSettings(
            redirectUri: Uri.parse('http://localhost:0'),
            scope: const ['openid'],
          ),
        );

    // This is the ticket 23 (second review round) regression: a manager
    // that LOSES the cross-isolate lock race must end up presenting the
    // WINNER's refreshed token on its next `refreshToken()` call, not the
    // stale pre-refresh token it still had in memory. `refreshToken()`
    // itself needs a live token endpoint to drive in a unit test, so this
    // asserts the actual mechanism `_readPersistedUser`/
    // `_readPersistedHeadlessUser` rely on instead: after
    // `adoptPersistedUser` runs, the manager's OWN `currentUser` (which is
    // exactly what a later `refreshToken()` call reads to find the refresh
    // token to present) and `userChanges()` both reflect the newly-adopted
    // user, not the one the manager held before.
    //
    // Against the pre-rework code, this fails: `LockedOidcUserManager` (and
    // its `adoptPersistedUser` method) did not exist at all - the loser's
    // long-lived manager was never told about the winner's refresh, so it
    // would keep reporting the stale, pre-refresh token forever.
    test(
        'adopting a fresh persisted user updates currentUser and '
        'userChanges() to the winner\'s refreshed token, not the stale '
        'pre-refresh one a loser\'s long-lived manager still held', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      expect(manager.currentUser, isNull);

      // Models the loser's long-lived manager BEFORE this round's lock
      // contention: it already holds SOME user, from whatever `init()` or
      // an earlier successful refresh restored - the pre-refresh token the
      // winner is about to rotate away on the server.
      final staleUser = await _buildTestUser(refreshToken: 'stale-refresh-token');
      await manager.adoptPersistedUser(staleUser);
      expect(manager.currentUser?.token.refreshToken, 'stale-refresh-token');

      final observed = <OidcUser?>[];
      final sub = manager.userChanges().listen(observed.add);
      // The value-caching stream replays the current value to a new
      // listener synchronously - wait one microtask turn so that replay is
      // observed before asserting on it below.
      await pumpEventQueue();
      expect(observed.single?.token.refreshToken, 'stale-refresh-token');

      // The lock's winner already refreshed and persisted a NEW token on
      // the server - this is what `_readPersistedUser`/
      // `_readPersistedHeadlessUser` feed back into THIS SAME manager via
      // `adoptPersistedUser`, rather than leaving it to find out on its
      // own (it never will - its own expiry-driven auto-refresh is
      // disabled; see `LockedOidcUserManager`'s class doc).
      final freshUser = await _buildTestUser(refreshToken: 'fresh-refresh-token');
      await manager.adoptPersistedUser(freshUser);

      // What any LATER `manager.refreshToken()` call on this manager would
      // present as the refresh token now reflects the winner's fresh one.
      expect(manager.currentUser?.token.refreshToken, 'fresh-refresh-token');

      await pumpEventQueue();
      expect(observed.last?.token.refreshToken, 'fresh-refresh-token');
      expect(observed.length, greaterThanOrEqualTo(2));

      await sub.cancel();
    });

    test('adopting a null persisted user clears currentUser without '
        'attempting to persist it', () async {
      final manager = buildManager();
      addTearDown(manager.dispose);

      final user = await _buildTestUser(refreshToken: 'some-refresh-token');
      await manager.adoptPersistedUser(user);
      expect(manager.currentUser, isNotNull);

      await manager.adoptPersistedUser(null);
      expect(manager.currentUser, isNull);
    });
  });
}
