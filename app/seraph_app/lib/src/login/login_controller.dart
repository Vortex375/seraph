import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';
import 'package:oidc/oidc.dart';
import 'package:oidc_default_store/oidc_default_store.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/sync/token_refresh_coordination.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/share/share_controller.dart';
import 'package:url_launcher/url_launcher.dart';

class LoginController extends GetxController with WidgetsBindingObserver {

  LoginController({
    required this.secureStorage,
    required this.settingsController,
    required this.shareController,
    required this.galleryMirror,
  }) {
    _initialized = false.obs;
    _noAuth = false.obs;
    _currentUser = Rx<OidcUser?>(null);
    _isSpaceAdmin = false.obs;
    
    if (settingsController.serverUrlConfirmed.value || kIsWeb) {
      init(settingsController.oidcIssuer.value, settingsController.oidcClientId.value);
    }
    settingsController.serverUrlConfirmed.listen((confirmed) {
      if (confirmed) {
        init(settingsController.oidcIssuer.value, settingsController.oidcClientId.value);
      }
    });
  }

  final FlutterSecureStorage secureStorage;
  final SettingsController settingsController;
  final ShareController shareController;

  /// Ticket 23: the shared persistent store [refreshTokenWithLock] guards
  /// every non-interactive refresh through, below - the SAME database
  /// (`gallery_mirror.sqlite`) the headless data-sync isolate's own
  /// `_loadHeadlessSession` (`../gallery/sync/gallery_sync_task_handler.dart`)
  /// reads and writes, which is what makes the lock cross-isolate rather
  /// than merely cross-call.
  final GalleryMirror galleryMirror;

  /// Always built via [_buildManager] (i.e. always a [LockedOidcUserManager])
  /// - see that method's doc and ticket 23's rule that no refresh may ever
  /// bypass [refreshTokenWithLock].
  LockedOidcUserManager? _manager;
  
  late Rx<bool> _initialized;
  late Rx<bool> _noAuth;
  late Rx<OidcUser?> _currentUser;
  late Rx<bool> _isSpaceAdmin;

  Rx<bool> get isInitialized => _initialized;
  Rx<bool> get isNoAuth => _noAuth;
  Rx<OidcUser?> get currentUser => _currentUser;
  Rx<bool> get isSpaceAdmin => _isSpaceAdmin;

  Future<void> init(String? oidcIssuer, String? clientId) async {
    if (kIsWeb) {
      return _initWeb();
    }

    if (oidcIssuer == null) {
      return _oidcDiscovery();
    }

    if (_manager != null) {
      _manager?.dispose();
      _manager = null;
    }
    _currentUser.value = null;
    
    if (oidcIssuer == '') {
      _noAuth.value = true;
      _initialized.value = true;
      _isSpaceAdmin.value = true;
      return;
    }

    _initialized.value = false;
    _noAuth.value = false;

    // redirectUri: kIsWeb
    // // this url must be an actual html page.
    // // see the file in /web/redirect.html for an example.
    // //
    // // for debugging in flutter, you must run this app with --web-port 22433
    // ? Uri.parse('http://localhost:22433/redirect.html')
    // : Platform.isIOS || Platform.isMacOS || Platform.isAndroid
    //     // scheme: reverse domain name notation of your package name.
    //     // path: anything.
    //     ? Uri.parse('com.bdayadev.oidc.example:/oauth2redirect')
    //     : Platform.isWindows || Platform.isLinux
    //         // using port 0 means that we don't care which port is used,
    //         // and a random unused port will be assigned.
    //         //
    //         // this is safer than passing a port yourself.
    //         //
    //         // note that you can also pass a path like /redirect,
    //         // but it's completely optional.
    //         ? Uri.parse('http://localhost:0')
    //         : Uri(),

    final manager = _buildManager(oidcIssuer, clientId!);
    _manager = manager;

    await manager.init();
    print("oidc: init complete");

    // Ticket 23: guarded rather than a bare `manager.refreshToken()` - with
    // the headless data-sync isolate potentially refreshing the SAME
    // rotating OIDC refresh token at the same moment (an overnight backup
    // still running when the user opens the app), an unguarded second
    // refresh here would present a token the other isolate's refresh had
    // already invalidated and silently end the session. If another isolate
    // currently holds the lock, this isolate never calls `refreshToken()`
    // itself - it waits, then reads whatever the winner persisted through a
    // throwaway probe manager's own `init()`, which also adopts that result
    // into [manager] (soon [_manager]) so it never keeps holding a rotated-
    // away token (see [_readPersistedUser]'s doc). [manager] is built via
    // [_buildManager] as a [LockedOidcUserManager], whose own internal
    // expiry-driven auto-refresh is disabled - this call is the ONLY path
    // to the token endpoint this manager ever takes.
    final user = await refreshTokenWithLock<OidcUser?>(
      mirror: galleryMirror,
      holder: uiTokenRefreshLockHolder,
      refresh: () => manager.refreshToken(),
      readPersisted: () => _readPersistedUser(manager, oidcIssuer, clientId),
    );
    if (user == null) {
      print("oidc: refresh failed -> perform login");
      await login();
    } else {
      print("oidc: refresh successful");
      _currentUser.value = user;
      _initialized.value = true;
      _updateSpaceAdmin(user);
    }
    
    _manager?.userChanges().listen((user) async {
      print('currentUser changed to ${user?.uid} ${user?.parsedIdToken.claims.toString()}');
      _currentUser.value = user;
      _initialized.value = true;
      shareController.loadShares();
      _updateSpaceAdmin(user);
    });
  }

  /// Builds a fresh [LockedOidcUserManager] against [oidcIssuer]/[clientId]
  /// - the exact construction [init] already did inline before ticket 23,
  /// now shared with [_readPersistedUser]'s throwaway probe manager below,
  /// so the two never drift apart on redirect URI, scope or store.
  ///
  /// Always [LockedOidcUserManager], never the plain package
  /// `OidcUserManager` - ticket 23's rule (set by the foreman after the
  /// first review round) is that NO call to the token endpoint may happen
  /// outside [refreshTokenWithLock], including ones the `oidc` package
  /// itself makes internally. [LockedOidcUserManager] closes the expiry-
  /// timer path; [lockedOidcSettings] (used for `settings`, below) closes
  /// `init()`'s own cached-token revalidation path. See both their class
  /// docs.
  LockedOidcUserManager _buildManager(String oidcIssuer, String clientId) {
    return LockedOidcUserManager.lazy(
      discoveryDocumentUri: OidcUtils.getOpenIdConfigWellKnownUri(
        Uri.parse(oidcIssuer),
      ),
      clientCredentials: OidcClientAuthentication.none(clientId: clientId),
      store: OidcDefaultStore(secureStorageInstance: secureStorage),
      settings: lockedOidcSettings(
        redirectUri: Platform.isIOS || Platform.isMacOS || Platform.isAndroid
            ? Uri.parse("net.umbasa.seraph.app:/oaut2redirect")
            : Uri.parse('http://localhost:0'),
        scope: const ["openid", "profile", "email", "offline_access"],
      ),
    );
  }

  /// Ticket 23's "re-reads the persisted token" side of the lock: a
  /// throwaway [LockedOidcUserManager], built fresh and `init()`'d then
  /// disposed, never reused for anything else. `.init()`'s own cold-start
  /// restore is what does the actual read - the SAME public path `.init()`
  /// already takes for [_manager] itself - so this deliberately does not
  /// reach for the package's protected `loadCachedTokens()`/
  /// `createUserFromToken()` internals just to save building a second
  /// manager. It never calls `.refreshToken()` itself; whatever `.init()`
  /// restores from [secureStorage] (already updated by the lock's winner,
  /// by the time this runs - see `refreshTokenWithLock`'s own doc) is
  /// authoritative.
  ///
  /// Critically, this also feeds the result into [liveManager] via
  /// [LockedOidcUserManager.adoptPersistedUser] - without that, [liveManager]
  /// (normally [_manager], the long-lived instance the rest of the app
  /// keeps using) would keep holding the PRE-refresh token in memory even
  /// though the lock's winner already rotated it away, so a LATER refresh
  /// attempt on [liveManager] would present an already-invalidated token.
  /// See [LockedOidcUserManager.adoptPersistedUser]'s own doc.
  Future<OidcUser?> _readPersistedUser(LockedOidcUserManager liveManager,
      String oidcIssuer, String clientId) async {
    final probe = _buildManager(oidcIssuer, clientId);
    try {
      await probe.init();
      final user = probe.currentUser;
      await liveManager.adoptPersistedUser(user);
      return user;
    } finally {
      await probe.dispose();
    }
  }

  Future<void> _initWeb() async {
    if (shareController.shareMode.value) {
      _noAuth.value = true;
      _initialized.value = true;
      return;
    }

    final dio = Dio(BaseOptions(
      baseUrl: settingsController.serverUrl.value,
      validateStatus: (status) => true,
    ));

    try {
      final response = await dio.get('/auth/login');
      print("*** login response");
      print(response);
      if (response.statusCode == 200) {
        _noAuth.value = true;
        _initialized.value = true;
        _isSpaceAdmin.value = true;
        shareController.loadShares();
      } else {
        await launchUrl(Uri.parse('${settingsController.serverUrl.value}/auth/login?'
          'redirect=true&to=${Uri.encodeFull(Uri.base.toString())}'),
          webOnlyWindowName: '_self');
      }
    } catch (err, stack) {
      print('oidc: web login check failed: $err');
      print(stack);
      Get.snackbar('Connection failed', 'Failed to connect to server: $err',
        backgroundColor: Colors.amber[800],
        isDismissible: true
      );
    }
  }

  Future<void> _oidcDiscovery() async {
    print("oidc: discovery");
    final dio = Dio(BaseOptions(baseUrl: settingsController.serverUrl.value));
    try {
      final response = await dio.get('/auth/config');
      final issuer = response.data['Issuer'];
      final clientId = response.data['AppClientId'];
      if (issuer == null) {
        print('no authentication');
        settingsController.setOidc('', '');
        init('', '');
      } else {
        print('yes authentication');
        settingsController.setOidc(issuer, clientId);
        init(issuer, clientId);
      }
    } catch (err, stack) {
      print('oidc: discovery failed: $err');
      print(stack);
      Get.snackbar('Connection failed', 'Failed to connect to server: $err',
        backgroundColor: Colors.amber[800],
        isDismissible: true
      );
      settingsController.setServerUrlConfirmed(false);
    }
  }

  Future<void> login() async {
    if (_manager == null) {
      return;
    }
    print("oidc: login");
    final newUser = await _manager?.loginAuthorizationCodeFlow();
    print("oidc: login complete");
    print(newUser);
  }

  Future<void> logout() async {
    if (_manager == null) {
      return;
    }
    print("oidc: logout");
    await _manager?.logout();
    _currentUser.value = null;
    _isSpaceAdmin.value = false;
    print("oidc: logout complete");
  }

  Future<void> refreshTokenIfNeeded() async {
    final manager = _manager;
    if (manager == null) {
      return;
    }
    if (!(manager.currentUser?.token.isAccessTokenAboutToExpire() ?? false)) {
      return;
    }
    final oidcIssuer = settingsController.oidcIssuer.value;
    final clientId = settingsController.oidcClientId.value;
    if (oidcIssuer == null || oidcIssuer.isEmpty || clientId == null) {
      // [_manager] only ever exists (see [init]) when both were non-empty
      // at the time it was built - this is just belt-and-suspenders against
      // a settings change racing this call.
      return;
    }
    // Ticket 23: same guard as `init()`, above, for the resume-triggered
    // refresh path. On the loser side, [_readPersistedUser] reads through a
    // throwaway probe manager AND adopts the result into [manager] itself
    // (`LockedOidcUserManager.adoptPersistedUser`) - required here more than
    // anywhere else, because [manager] is [_manager], the SAME long-lived
    // instance every later resume (and this same method, next time it
    // fires) keeps calling `refreshToken()` on. Without adopting, [manager]
    // would keep the pre-refresh token in memory and eventually present it
    // again - `LockedOidcUserManager` no longer has its own internal expiry
    // timer to catch that for us (see that class's doc), so there is no
    // other path back to a fresh token here.
    await refreshTokenWithLock<OidcUser?>(
      mirror: galleryMirror,
      holder: uiTokenRefreshLockHolder,
      refresh: () => manager.refreshToken(),
      readPersisted: () => _readPersistedUser(manager, oidcIssuer, clientId),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
      /* manually refresh token on resume */
        refreshTokenIfNeeded();
        break;
      default:
    }
  }

  @override
  void onInit() {
    super.onInit();

    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void onClose() {
    super.onClose();

    WidgetsBinding.instance.removeObserver(this);
  }

  void _updateSpaceAdmin(OidcUser? user) {
    if (user == null) {
      _isSpaceAdmin.value = false;
      return;
    }

    // Check userInfo for roles claim
    final userInfo = user.userInfo;
    final roles = userInfo['roles'];
    if (roles is List && roles.any((r) => r.toString() == 'space-admin')) {
      _isSpaceAdmin.value = true;
      return;
    }
    // Also check common Zitadel claim patterns
    for (final key in userInfo.keys) {
      if (key.toString().contains('roles')) {
        final value = userInfo[key];
        if (value is List &&
            value.any((r) => r.toString() == 'space-admin')) {
          _isSpaceAdmin.value = true;
          return;
        }
      }
    }

    // Check parsed ID token claims
    final claims = user.parsedIdToken.claims.toJson();
    for (final key in claims.keys) {
        if (key.toString().contains('roles')) {
          final value = claims[key];
          if (value is List &&
              value.any((r) => r.toString() == 'space-admin')) {
            _isSpaceAdmin.value = true;
            return;
          }
        }
      }

    _isSpaceAdmin.value = false;
  }
}