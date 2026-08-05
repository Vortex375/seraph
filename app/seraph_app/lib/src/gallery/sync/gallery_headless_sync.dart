import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:oidc/oidc.dart';
import 'package:oidc_default_store/oidc_default_store.dart';
import 'package:seraph_app/src/gallery/local/android_local_source.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_upload_backend.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_upload_service.dart';
import 'package:seraph_app/src/gallery/sync/gallery_sync_engine.dart';
import 'package:seraph_app/src/gallery/sync/token_refresh_coordination.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

/// Everything a headless (no-UI, no-GetX) Dart isolate needs to run
/// [GallerySyncEngine] against the currently configured server, shared
/// between ticket 22's foreground data-sync service
/// (`gallery_sync_task_handler.dart`) and ticket 24's scheduled background
/// work (`gallery_backup_scheduler_io.dart`).
///
/// Pulled out of `gallery_sync_task_handler.dart` (where ticket 22 and 23
/// first wrote it) into its own file for ticket 24: two DIFFERENT Android
/// entrypoints now need to build a non-interactive OIDC session and run the
/// engine from a cold isolate - the user-initiated `dataSync` foreground
/// service (ticket 22) and WorkManager's periodic/expedited callback (ticket
/// 24). Ticket 23's rule - "no call to the token endpoint may happen outside
/// [refreshTokenWithLock], from any code path" - is a rule about there being
/// exactly ONE such code path, not merely no *known* violation of it; a
/// second, independently-written copy of this session-loading logic in the
/// scheduler would be exactly the kind of divergence that rule exists to
/// prevent. Both entrypoints now call [runHeadlessGallerySync].
///
/// **No UI dependencies of any kind** - the same "headless by construction"
/// property [GallerySyncEngine] itself has (see its own class doc):
/// nothing here imports `package:flutter`, GetX, or `BuildContext`.

/// What [loadHeadlessSyncSession] hands its caller: enough to build a WebDAV
/// client against the currently configured server, with whatever bearer
/// token (if any - a no-auth server has none) the persisted OIDC session
/// currently holds.
///
/// [refreshToken], when non-null, refreshes the session's access token
/// in-place - updating [client]'s `Authorization` header so the next
/// request on it uses the fresh bearer. [HeadlessWebDavBackend] calls it
/// via [withTokenRecovery] on a 401/403, the gateway's "your access token
/// is no good" response: without it, an access token that expired mid-run
/// (its lifetime is short - 5 minutes, for the test realm - and a backup
/// runs for hours) would surface as a permanent "read-only Space" failure
/// the engine parks in the visible failure list rather than recovering
/// from. Null for a no-auth server (no token to refresh).
class HeadlessSyncSession {
  const HeadlessSyncSession(this.client, {this.refreshToken});

  final webdav.Client client;

  /// Refreshes [client]'s bearer token under the cross-isolate lock
  /// ([refreshTokenWithLock]) and updates its headers in-place. See the
  /// class doc for why this exists and when it is null.
  final Future<void> Function()? refreshToken;
}

/// Ticket 24's `SyncRunLock` holder identity for ticket 22's foreground
/// `dataSync` service.
const String syncRunLockHolderForegroundService = 'foreground-service';

/// Ticket 24's `SyncRunLock` holder identity for the WorkManager-triggered
/// path (periodic, content-trigger, or fast-path task alike - all three run
/// inside the same callback dispatcher isolate, one at a time, so they share
/// one holder identity; the lock's job is only to keep THAT isolate class
/// from overlapping with the foreground service, not to distinguish which
/// of the three woke it).
const String syncRunLockHolderWorkManager = 'workmanager';

/// How long a [GalleryMirror.tryAcquireSyncRunLock] lease lasts before it is
/// treated as free again if never renewed - the bound on how long a runner
/// killed mid-lease can block the other path (ticket 23's same "does not
/// deadlock" guarantee, see [SyncRunLock]'s own class doc). Short relative to
/// a real run's total duration on purpose: [runHeadlessGallerySync] renews
/// it well before this elapses (see [_syncRunLockRenewInterval]), so a lease
/// this short only matters for how quickly a KILLED holder's lock frees up,
/// not for how long a healthy run can hold it.
const int _syncRunLockLeaseMillis = 5 * 60 * 1000;

/// How often [runHeadlessGallerySync] renews its own lease while an engine
/// run is in progress - comfortably inside [_syncRunLockLeaseMillis] so a
/// slow renewal (a busy isolate, a slow SQLite write) never races the lease
/// actually expiring out from under a still-healthy run.
const Duration _syncRunLockRenewInterval = Duration(minutes: 2);

/// What [runHeadlessGallerySync] did - distinguishes "the engine ran and
/// produced [result]" from the two reasons it did not, which callers need to
/// tell apart: a session failure is worth telling the user about (ticket
/// 22's "not signed in" notification), while [lockBusy] means another
/// runner already holds the engine and there is nothing wrong at all - the
/// caller should simply stand down quietly, since whichever runner won is
/// already the one writing [SyncRunState].
class HeadlessSyncAttempt {
  const HeadlessSyncAttempt._({this.result, this.lockBusy = false});

  /// The engine actually ran to completion (or pause) and produced [result].
  const HeadlessSyncAttempt.ran(GallerySyncEngineResult result)
      : this._(result: result);

  /// No session could be obtained - [SyncRunState.lastError] has already
  /// been written by [loadHeadlessSyncSession]'s caller here, describing
  /// why.
  const HeadlessSyncAttempt.noSession() : this._();

  /// Another runner already held [GalleryMirror.tryAcquireSyncRunLock] -
  /// ticket 24's "background and foreground runs do not both process the
  /// same photo" guarantee refusing this attempt outright, before it ever
  /// touched a session or constructed an engine. [SyncRunState] is
  /// deliberately untouched by this outcome - the winner is already writing
  /// it.
  const HeadlessSyncAttempt.lockBusy() : this._(lockBusy: true);

  /// Non-null only for [HeadlessSyncAttempt.ran].
  final GallerySyncEngineResult? result;

  /// True only for [HeadlessSyncAttempt.lockBusy].
  final bool lockBusy;
}

/// Runs one [GallerySyncEngine.run] against [db], from a cold start, guarded
/// by ticket 24's [SyncRunLock] so this is the ONE place either headless
/// entrypoint can ever construct a [GallerySyncEngine] - see
/// [HeadlessSyncAttempt]'s own doc for why that guard has to live here
/// rather than in each caller separately (both
/// `gallery_sync_task_handler.dart` and `gallery_backup_scheduler_io.dart`
/// call this function, and nothing else in either file touches
/// [GallerySyncEngine] directly).
///
/// [lockHolder] identifies the caller for [GalleryMirror.tryAcquireSyncRunLock]
/// - [syncRunLockHolderForegroundService] or [syncRunLockHolderWorkManager].
///
/// If the lock is free (or already held by [lockHolder] itself), acquires
/// it, then obtains a non-interactive session ([loadHeadlessSyncSession}),
/// builds the engine's dependencies from scratch (there is no
/// `InitialBinding`-registered singleton to reuse in a cold isolate), runs
/// it, and releases the lock in a `finally` - success, failure, or exception
/// alike. While the engine runs, a timer renews the lease every
/// [_syncRunLockRenewInterval] so a run that legitimately spans hours (an
/// unattended overnight backlog, or a large user-initiated foreground batch)
/// is never mistaken for a dead holder and preempted mid-flight; a holder
/// that stops renewing (killed) simply lets the lease lapse, which is what
/// keeps this from deadlocking the other path.
///
/// [onEngineReady], if given, is called with the constructed engine before
/// [GallerySyncEngine.run] starts - the foreground task handler uses this to
/// keep a reference for its own notification button/`onReceiveData` pause
/// wiring, something the simpler WorkManager callback has no need for and
/// simply omits.
Future<HeadlessSyncAttempt> runHeadlessGallerySync(
  GalleryMirrorDatabase db, {
  required String lockHolder,
  void Function(GallerySyncEngine engine)? onEngineReady,
}) async {
  final mirror = GalleryMirror(db);

  final acquired = await mirror.tryAcquireSyncRunLock(
    holder: lockHolder,
    nowMillis: DateTime.now().millisecondsSinceEpoch,
    leaseMillis: _syncRunLockLeaseMillis,
  );
  if (!acquired) {
    return const HeadlessSyncAttempt.lockBusy();
  }

  Timer? renewal;
  try {
    renewal = Timer.periodic(_syncRunLockRenewInterval, (_) {
      unawaited(mirror.tryAcquireSyncRunLock(
        holder: lockHolder,
        nowMillis: DateTime.now().millisecondsSinceEpoch,
        leaseMillis: _syncRunLockLeaseMillis,
      ));
    });

    final session = await loadHeadlessSyncSession(mirror);
    if (session == null) {
      await mirror.writeSyncRunState(
        status: syncStatusError,
        totalItems: 0,
        completedItems: 0,
        failedItems: 0,
        totalBytes: 0,
        completedBytes: 0,
        lastError: 'Not signed in - open Seraph to sign in, then start '
            'backup again.',
        updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
      );
      return const HeadlessSyncAttempt.noSession();
    }

    final backend = HeadlessWebDavBackend(session);
    final localSource = AndroidLocalSource();
    final uploadService = GalleryUploadService(mirror, backend, localSource);
    final engine = GallerySyncEngine(mirror, uploadService);
    onEngineReady?.call(engine);

    try {
      final result = await engine.run();
      return HeadlessSyncAttempt.ran(result);
    } finally {
      localSource.dispose();
    }
  } finally {
    renewal?.cancel();
    await mirror.releaseSyncRunLock(holder: lockHolder);
  }
}

/// Obtains a WebDAV client for the currently configured server, reusing
/// exactly the persisted state `LoginController` reads on the app's own cold
/// start - the same `SettingsController`-held server URL/OIDC issuer/client
/// id, and the same `flutter_secure_storage`-backed [OidcDefaultStore] token
/// cache - but **deliberately stops at a non-interactive refresh** rather
/// than reconstructing `LoginController` itself.
///
/// This is a decision the ticket did not settle: `LoginController`'s own
/// `init()` falls back to `OidcUserManager.loginAuthorizationCodeFlow()` -
/// which opens a browser - whenever a refresh fails, and that is exactly
/// the one thing a headless service isolate with no window to show a login
/// page in must never attempt. So this function performs the SAME refresh
/// `LoginController.init()` performs on cold start (`OidcUserManager.lazy`,
/// `.init()`, `.refreshToken()`) and, if that comes back with no user,
/// returns null - the caller then aborts the run with a comprehensible
/// [SyncRunState.lastError] instead of ever reaching the interactive flow. A
/// user whose session has expired finds out by opening the app (which still
/// does its own normal, interactive login there) rather than by a
/// background service silently popping a browser over whatever they were
/// doing on their phone.
///
/// **Ticket 23**: the explicit `.refreshToken()` call is guarded by the same
/// cross-isolate lock [LoginController] itself now goes through
/// (`refreshTokenWithLock`, `token_refresh_coordination.dart`) - [mirror] is
/// this isolate's own connection to the SAME `gallery_mirror.sqlite` file
/// the UI isolate (and, since ticket 24, any other headless isolate) has
/// open, which is what makes the lock cross-isolate rather than merely
/// cross-call. If another isolate's own refresh currently holds the lock,
/// this call never presents the rotating refresh token a second time - it
/// waits, then reads whatever that isolate's refresh persisted instead.
///
/// Returns null (rather than throwing) for every case that just means
/// "there is nothing to back up to right now": no server ever confirmed, no
/// OIDC discovery ever completed, or a refresh that failed. `serverUrlConfirmed`
/// with an empty [SettingsController.oidcIssuer] means a no-auth server -
/// the session then carries no token at all, which is exactly what an
/// unauthenticated [webdav.Client] needs.
Future<HeadlessSyncSession?> loadHeadlessSyncSession(
    GalleryMirror mirror) async {
  final settingsController = SettingsController();
  await settingsController.init();

  if (!settingsController.serverUrlConfirmed.value) {
    return null;
  }
  final serverUrl = settingsController.serverUrl.value;
  final issuer = settingsController.oidcIssuer.value;

  if (issuer == null) {
    // Discovery (LoginController._oidcDiscovery) never completed on this
    // device - nothing this isolate should attempt on its own.
    return null;
  }

  if (issuer == '') {
    // A no-auth server (LoginController's own `oidcIssuer == ''` case) -
    // no token needed at all.
    return HeadlessSyncSession(
        webdav.newClient('$serverUrl/dav/p', debug: false));
  }

  final clientId = settingsController.oidcClientId.value;
  if (clientId == null) {
    return null;
  }

  final manager = buildHeadlessOidcManager(issuer, clientId);

  try {
    await manager.init();
    // Ticket 23: guarded rather than a bare `manager.refreshToken()` - see
    // this function's own doc. The loser reads via a throwaway probe
    // manager's `init()` ([readPersistedHeadlessUser]), which also adopts
    // that result into [manager] itself (`LockedOidcUserManager.
    // adoptPersistedUser`) so it never keeps holding a rotated-away token -
    // required here even more than in `LoginController`, since this isolate
    // can run for hours during an overnight backup, spanning several token
    // lifetimes. [manager] is built via [buildHeadlessOidcManager] as a
    // [LockedOidcUserManager], whose own internal expiry-driven auto-refresh
    // is disabled - this call is the ONLY path to the token endpoint this
    // manager ever takes.
    final user = await refreshTokenWithLock<OidcUser?>(
      mirror: mirror,
      holder: headlessTokenRefreshLockHolder,
      refresh: () => manager.refreshToken(),
      readPersisted: () =>
          readPersistedHeadlessUser(manager, issuer, clientId),
    );
    if (user == null) {
      return null;
    }
    final client = webdav.newClient('$serverUrl/dav/p', debug: false);
    client.setHeaders({'Authorization': 'Bearer ${user.token.accessToken}'});

    // The reactive refresh callback [HeadlessWebDavBackend] hands to
    // [withTokenRecovery] on a 401/403 - the gateway's "expired access
    // token" response, which an hours-long backup hits every time the
    // short-lived access token (5 minutes, for the test realm) elapses.
    // Builds a FRESH [LockedOidcUserManager] each call (the one used for
    // the initial refresh, above, is disposed in this function's `finally`
    // before the engine even starts) and refreshes it under the SAME
    // cross-isolate lock the initial refresh used, then updates [client]'s
    // headers in-place so the retry picks up the new bearer without the
    // backend needing to know how a token is obtained.
    Future<void> refreshSessionToken() async {
      final refreshManager = buildHeadlessOidcManager(issuer, clientId);
      try {
        await refreshManager.init();
        final refreshed = await refreshTokenWithLock<OidcUser?>(
          mirror: mirror,
          holder: headlessTokenRefreshLockHolder,
          refresh: () => refreshManager.refreshToken(),
          readPersisted: () =>
              readPersistedHeadlessUser(refreshManager, issuer, clientId),
        );
        if (refreshed != null) {
          client.setHeaders(
              {'Authorization': 'Bearer ${refreshed.token.accessToken}'});
        }
      } finally {
        await refreshManager.dispose();
      }
    }

    return HeadlessSyncSession(client, refreshToken: refreshSessionToken);
  } catch (_) {
    return null;
  } finally {
    await manager.dispose();
  }
}

/// Builds a fresh [LockedOidcUserManager] against [issuer]/[clientId] - the
/// exact construction every headless entrypoint needs, shared so the two
/// never drift apart on redirect URI, scope or store.
///
/// Always [LockedOidcUserManager], never the plain package
/// `OidcUserManager` - ticket 23's rule (set by the foreman after the first
/// review round) is that NO call to the token endpoint may happen outside
/// [refreshTokenWithLock], including ones the `oidc` package itself makes
/// internally. This matters most for a headless isolate, which can run
/// unattended for hours during an overnight backup - the worst place to
/// leave either of the package's own internal refresh paths armed.
/// [LockedOidcUserManager] closes the expiry-timer path; [lockedOidcSettings]
/// (used for `settings`, below) closes `init()`'s own cached-token
/// revalidation path. See both their class docs
/// (`token_refresh_coordination.dart`).
LockedOidcUserManager buildHeadlessOidcManager(String issuer, String clientId) {
  const secureStorage = FlutterSecureStorage();
  return LockedOidcUserManager.lazy(
    discoveryDocumentUri: OidcUtils.getOpenIdConfigWellKnownUri(Uri.parse(issuer)),
    clientCredentials: OidcClientAuthentication.none(clientId: clientId),
    store: OidcDefaultStore(secureStorageInstance: secureStorage),
    settings: lockedOidcSettings(
      redirectUri: Uri.parse('net.umbasa.seraph.app:/oaut2redirect'),
      scope: const ['openid', 'profile', 'email', 'offline_access'],
    ),
  );
}

/// Ticket 23's "re-reads the persisted token" side of the lock, for a
/// headless isolate - mirrors `LoginController`'s own `_readPersistedUser`
/// (`../../login/login_controller.dart`): a throwaway
/// [LockedOidcUserManager], built fresh and `init()`'d then disposed, never
/// reused for anything else, so the read goes through the package's public
/// cold-start restore path rather than its protected `loadCachedTokens()`/
/// `createUserFromToken()` internals. Never calls `.refreshToken()` itself -
/// whatever `.init()` restores from secure storage (already updated by the
/// lock's winner, by the time this runs) is authoritative.
///
/// Critically, this also feeds the result into [liveManager] via
/// [LockedOidcUserManager.adoptPersistedUser] - without that, [liveManager]
/// (the manager [loadHeadlessSyncSession] goes on to use for the rest of
/// this run) would keep holding the PRE-refresh token in memory even though
/// the lock's winner already rotated it away, so this isolate would present
/// an already-invalidated refresh token the next time IT thinks a refresh is
/// due - the exact overnight-backup logout ticket 23 exists to prevent, and
/// the isolate most likely to actually hit it, since it can run for hours.
Future<OidcUser?> readPersistedHeadlessUser(
    LockedOidcUserManager liveManager, String issuer, String clientId) async {
  final probe = buildHeadlessOidcManager(issuer, clientId);
  try {
    await probe.init();
    final user = probe.currentUser;
    await liveManager.adoptPersistedUser(user);
    return user;
  } finally {
    await probe.dispose();
  }
}

/// A [GalleryUploadBackend] talking to `webdav_client` directly, over the
/// session [loadHeadlessSyncSession] obtained - not
/// `WebDavGalleryUploadBackend` (in `../mirror/webdav_gallery_upload_backend
/// .dart`), which is built on `FileService`/`LoginController` and therefore
/// carries the interactive-login risk [loadHeadlessSyncSession]'s doc explains
/// a headless isolate must avoid.
/// Shares [translateWebDavError] with `WebDavGalleryUploadBackend` so the
/// two report identical, already-tested messages for the same server
/// responses rather than a second, drifting copy of that mapping.
///
/// Every operation is wrapped in [withTokenRecovery]: a 401/403 from the
/// gateway (the auth middleware's "expired access token" response - the
/// SAME status a genuinely read-only Space produces) triggers one
/// [HeadlessSyncSession.refreshToken] and a single retry. Without this, an
/// access token that expired mid-run (its lifetime is short - 5 minutes,
/// for the test realm - and a backup runs for hours) would surface as a
/// permanent "read-only Space" failure the engine parks in the failure
/// list rather than recovering from - the exact symptom the backup feature
/// reports.
class HeadlessWebDavBackend implements GalleryUploadBackend {
  HeadlessWebDavBackend(this._session);

  final HeadlessSyncSession _session;

  webdav.Client get _client => _session.client;

  String _path(String spaceProviderId, String path) {
    final rel = path.startsWith('/') ? path : '/$path';
    return '/$spaceProviderId$rel';
  }

  @override
  Future<int?> statSize(String spaceProviderId, String path) async {
    try {
      return await withTokenRecovery<int?>(
        op: () async {
          try {
            final file = await _client.readProps(_path(spaceProviderId, path));
            return file.size;
          } on DioException catch (e) {
            if (e.response?.statusCode == 404) {
              return null;
            }
            rethrow;
          }
        },
        refreshToken: _session.refreshToken ?? () async {},
        translate: translateWebDavError,
      );
    } on GalleryUploadException {
      rethrow;
    }
  }

  @override
  Future<void> put(
      String spaceProviderId, String path, Uint8List bytes) async {
    await withTokenRecovery<void>(
      op: () async => _client.write(_path(spaceProviderId, path), bytes),
      refreshToken: _session.refreshToken ?? () async {},
      translate: translateWebDavError,
    );
  }

  @override
  Future<void> remove(String spaceProviderId, String path) async {
    try {
      await withTokenRecovery<void>(
        op: () async {
          try {
            await _client.remove(_path(spaceProviderId, path));
          } on DioException catch (e) {
            if (e.response?.statusCode == 404) {
              return;
            }
            rethrow;
          }
        },
        refreshToken: _session.refreshToken ?? () async {},
        translate: translateWebDavError,
      );
    } on GalleryUploadException {
      rethrow;
    }
  }
}
