import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
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

/// The headless isolate's entry point (`gallery_data_sync_service_io.dart`
/// registers this as `startService`'s `callback`). **This is what makes the
/// engine "a headless Dart isolate" rather than a figure of speech**:
/// `flutter_foreground_task` spawns a genuinely separate `FlutterEngine` for
/// Android's `dataSync` foreground service and runs this function there, with
/// no `BuildContext`, no widget tree, and none of the `Get.put`-registered
/// singletons `InitialBinding` sets up for the app's own UI isolate - every
/// dependency [_GallerySyncTaskHandler] needs, it constructs for itself, from
/// the same persisted state (secure storage, settings) the UI isolate reads
/// on its own cold start.
@pragma('vm:entry-point')
void galleryDataSyncCallback() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(_GallerySyncTaskHandler());
}

/// A signal sent over [FlutterForegroundTask.sendDataToTask] - from
/// [GalleryDataSyncController] via the real service
/// (`gallery_data_sync_service_io.dart`) - asking the running engine to
/// pause. The paired notification button uses the same string as its id, so
/// [TaskHandler.onNotificationButtonPressed] and [TaskHandler.onReceiveData]
/// can share one handler.
const String pauseSignal = 'pause';

/// The counterpart signal, sent when [GalleryDataSyncController.start] finds
/// the service already alive (the paused-but-not-stopped case - see
/// [_GallerySyncTaskHandler._runOnce]'s doc for why a paused run leaves the
/// service running rather than stopping it) - runs [GallerySyncEngine.run]
/// again rather than restarting the whole isolate from scratch.
const String resumeSignal = 'resume';

/// Runs [GallerySyncEngine] inside the foreground service's own isolate.
///
/// **No UI dependencies reach this class** - it talks to
/// [GalleryMirrorDatabase] and [GalleryUploadBackend] alone, exactly like
/// [GallerySyncEngine] itself; the only `flutter_foreground_task` API it
/// touches is updating its OWN notification text and reacting to its OWN
/// notification's button, neither of which is "the UI" in the sense ticket
/// 22's "the UI reflects engine state by observing the local database, not
/// by being called by the engine" criterion means (see [GallerySyncEngine]'s
/// own class doc) - the app's actual Flutter UI
/// ([GalleryDataSyncController]) never receives a call from this isolate at
/// all, only from independently polling [GalleryMirror.syncRunState].
class _GallerySyncTaskHandler extends TaskHandler {
  GalleryMirrorDatabase? _db;
  GallerySyncEngine? _engine;
  Timer? _notificationTimer;
  bool _running = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    unawaited(_runOnce());
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    unawaited(_updateNotification());
  }

  @override
  void onReceiveData(Object data) {
    if (data == pauseSignal) {
      _engine?.requestPause();
    } else if (data == resumeSignal) {
      unawaited(_runOnce());
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == pauseSignal) {
      _engine?.requestPause();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _notificationTimer?.cancel();
    await _db?.close();
  }

  /// Bootstraps every dependency [GallerySyncEngine] needs from scratch (see
  /// the class doc), runs one [GallerySyncEngine.run], updates the
  /// notification once more with the final outcome, then stops the
  /// foreground service itself - a run that finished (whether by draining
  /// the queue or by [pauseSignal]) has nothing left to do in the
  /// background, and Android discourages a foreground service that sits
  /// idle.
  ///
  /// A session that cannot be obtained (never logged in on this device, or
  /// the persisted session has expired) aborts the run with
  /// [SyncRunState.lastError] set, rather than the one thing this isolate
  /// must never do: fall back to an interactive login flow with no UI to
  /// show it in. See [_loadHeadlessSession]'s doc.
  Future<void> _runOnce() async {
    if (_running) {
      return;
    }
    _running = true;
    try {
      final db = _db ??= GalleryMirrorDatabase.open();
      final mirror = GalleryMirror(db);

      final session = await _loadHeadlessSession(mirror);
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
        await FlutterForegroundTask.updateService(
          notificationTitle: 'Backup could not start',
          notificationText: 'Not signed in - open Seraph to sign in.',
        );
        await FlutterForegroundTask.stopService();
        return;
      }

      final backend = _HeadlessWebDavBackend(session.client);
      final localSource = AndroidLocalSource();
      final uploadService = GalleryUploadService(mirror, backend, localSource);
      final engine = _engine ??= GallerySyncEngine(mirror, uploadService);

      _notificationTimer ??=
          Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_updateNotification());
      });

      final result = await engine.run();
      await _updateNotification();
      localSource.dispose();

      if (result.outcome != GallerySyncOutcome.paused) {
        await FlutterForegroundTask.stopService();
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _updateNotification() async {
    final db = _db;
    if (db == null) {
      return;
    }
    final state = await GalleryMirror(db).syncRunState();
    final remaining =
        (state.totalItems - state.completedItems - state.failedItems)
            .clamp(0, state.totalItems);
    final remainingMb =
        ((state.totalBytes - state.completedBytes) / (1024 * 1024))
            .clamp(0, double.infinity);
    final text = switch (state.status) {
      syncStatusRunning =>
        '$remaining photo${remaining == 1 ? '' : 's'} left '
            '(~${remainingMb.toStringAsFixed(1)} MB)',
      syncStatusCompleted => state.totalItems == 0
          ? 'Everything is backed up'
          : 'Backup complete - ${state.completedItems} photo'
              '${state.completedItems == 1 ? '' : 's'} sent',
      syncStatusPaused => 'Paused - $remaining photo'
          '${remaining == 1 ? '' : 's'} left',
      _ => 'Backing up…',
    };
    await FlutterForegroundTask.updateService(
      notificationTitle: 'Seraph backup',
      notificationText: text,
    );
  }
}

/// What [_loadHeadlessSession] hands the task handler: enough to build a
/// WebDAV client against the currently configured server, with whatever
/// bearer token (if any - a no-auth server has none) the persisted OIDC
/// session currently holds.
class _HeadlessSession {
  const _HeadlessSession(this.client);
  final webdav.Client client;
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
/// returns null - the caller ([_GallerySyncTaskHandler._runOnce]) then
/// aborts the run with a comprehensible [SyncRunState.lastError] instead of
/// ever reaching the interactive flow. A user whose session has expired
/// finds out by opening the app (which still does its own normal,
/// interactive login there) rather than by a background service silently
/// popping a browser over whatever they were doing on their phone.
///
/// **Ticket 23**: the explicit `.refreshToken()` call is guarded by the same
/// cross-isolate lock [LoginController] itself now goes through
/// (`refreshTokenWithLock`, `token_refresh_coordination.dart`) - [mirror] is
/// this isolate's own connection to the SAME `gallery_mirror.sqlite` file
/// the UI isolate has open, which is what makes the lock cross-isolate
/// rather than merely cross-call. If the UI isolate's own refresh currently
/// holds the lock, this call never presents the rotating refresh token a
/// second time - it waits, then reads whatever the UI isolate's refresh
/// persisted instead.
///
/// Returns null (rather than throwing) for every case that just means
/// "there is nothing to back up to right now": no server ever confirmed, no
/// OIDC discovery ever completed, or a refresh that failed. `serverUrlConfirmed`
/// with an empty [SettingsController.oidcIssuer] means a no-auth server -
/// the session then carries no token at all, which is exactly what an
/// unauthenticated [webdav.Client] needs.
Future<_HeadlessSession?> _loadHeadlessSession(GalleryMirror mirror) async {
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
    return _HeadlessSession(webdav.newClient('$serverUrl/dav/p', debug: false));
  }

  final clientId = settingsController.oidcClientId.value;
  if (clientId == null) {
    return null;
  }

  final manager = _buildHeadlessManager(issuer, clientId);

  try {
    await manager.init();
    // Ticket 23: guarded rather than a bare `manager.refreshToken()` - see
    // this function's own doc. The loser reads via a throwaway probe
    // manager's `init()` ([_readPersistedHeadlessUser]) rather than
    // reaching for the package's protected `loadCachedTokens()` internals.
    final user = await refreshTokenWithLock<OidcUser?>(
      mirror: mirror,
      holder: headlessTokenRefreshLockHolder,
      refresh: () => manager.refreshToken(),
      readPersisted: () => _readPersistedHeadlessUser(issuer, clientId),
    );
    if (user == null) {
      return null;
    }
    final client = webdav.newClient('$serverUrl/dav/p', debug: false);
    client.setHeaders({'Authorization': 'Bearer ${user.token.accessToken}'});
    return _HeadlessSession(client);
  } catch (_) {
    return null;
  } finally {
    await manager.dispose();
  }
}

/// Builds a fresh [OidcUserManager] against [issuer]/[clientId] - the exact
/// construction [_loadHeadlessSession] already did inline before ticket 23,
/// now shared with [_readPersistedHeadlessUser]'s throwaway probe manager
/// below, so the two never drift apart on redirect URI, scope or store.
OidcUserManager _buildHeadlessManager(String issuer, String clientId) {
  const secureStorage = FlutterSecureStorage();
  return OidcUserManager.lazy(
    discoveryDocumentUri: OidcUtils.getOpenIdConfigWellKnownUri(Uri.parse(issuer)),
    clientCredentials: OidcClientAuthentication.none(clientId: clientId),
    store: OidcDefaultStore(secureStorageInstance: secureStorage),
    settings: OidcUserManagerSettings(
      redirectUri: Uri.parse('net.umbasa.seraph.app:/oaut2redirect'),
      scope: const ['openid', 'profile', 'email', 'offline_access'],
    ),
  );
}

/// Ticket 23's "re-reads the persisted token" side of the lock, for the
/// headless isolate - mirrors [LoginController]'s own
/// `_readPersistedUser` (`../../login/login_controller.dart`): a throwaway
/// manager, built fresh and `init()`'d then disposed, never reused, so the
/// read goes through the package's public cold-start restore path rather
/// than its protected `loadCachedTokens()`/`createUserFromToken()`
/// internals. Never calls `.refreshToken()` itself - whatever `.init()`
/// restores from secure storage (already updated by the lock's winner, by
/// the time this runs) is authoritative.
Future<OidcUser?> _readPersistedHeadlessUser(
    String issuer, String clientId) async {
  final probe = _buildHeadlessManager(issuer, clientId);
  try {
    await probe.init();
    return probe.currentUser;
  } finally {
    await probe.dispose();
  }
}

/// A [GalleryUploadBackend] talking to `webdav_client` directly, over the
/// session [_loadHeadlessSession] obtained - not [WebDavGalleryUploadBackend],
/// which is built on [FileService]/`LoginController` and therefore carries
/// the interactive-login risk [_loadHeadlessSession]'s doc explains this
/// isolate must avoid. Shares [translateWebDavError] with
/// [WebDavGalleryUploadBackend] so the two report identical, already-tested
/// messages for the same server responses rather than a second, drifting
/// copy of that mapping.
class _HeadlessWebDavBackend implements GalleryUploadBackend {
  _HeadlessWebDavBackend(this._client);

  final webdav.Client _client;

  String _path(String spaceProviderId, String path) {
    final rel = path.startsWith('/') ? path : '/$path';
    return '/$spaceProviderId$rel';
  }

  @override
  Future<int?> statSize(String spaceProviderId, String path) async {
    try {
      final file = await _client.readProps(_path(spaceProviderId, path));
      return file.size;
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return null;
      }
      throw translateWebDavError(e, e.response?.statusCode);
    }
  }

  @override
  Future<void> put(
      String spaceProviderId, String path, Uint8List bytes) async {
    try {
      await _client.write(_path(spaceProviderId, path), bytes);
    } on DioException catch (e) {
      throw translateWebDavError(e, e.response?.statusCode);
    }
  }

  @override
  Future<void> remove(String spaceProviderId, String path) async {
    try {
      await _client.remove(_path(spaceProviderId, path));
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) {
        return;
      }
      throw translateWebDavError(e, e.response?.statusCode);
    }
  }
}
