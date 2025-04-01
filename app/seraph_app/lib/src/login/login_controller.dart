import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';
import 'package:oidc/oidc.dart';
import 'package:oidc_default_store/oidc_default_store.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/share/share_controller.dart';
import 'package:url_launcher/url_launcher.dart';

class LoginController extends GetxController with WidgetsBindingObserver {

  LoginController({required this.secureStorage, required this.settingsController, required this.shareController}) {
    _initialized = false.obs;
    _noAuth = false.obs;
    _currentUser = Rx<OidcUser?>(null);
    
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

  OidcUserManager? _manager;
  
  late Rx<bool> _initialized;
  late Rx<bool> _noAuth;
  late Rx<OidcUser?> _currentUser;

  Rx<bool> get isInitialized => _initialized;
  Rx<bool> get isNoAuth => _noAuth;
  Rx<OidcUser?> get currentUser => _currentUser;

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

    _manager = OidcUserManager.lazy(
      discoveryDocumentUri: OidcUtils.getOpenIdConfigWellKnownUri(
          Uri.parse(oidcIssuer),
      ),
      clientCredentials: OidcClientAuthentication.none(clientId: clientId!),
      store: OidcDefaultStore(secureStorageInstance: secureStorage),
      settings: OidcUserManagerSettings(
        redirectUri: Platform.isIOS || Platform.isMacOS || Platform.isAndroid 
            ? Uri.parse("net.umbasa.seraph.app:/oaut2redirect")
            : Uri.parse('http://localhost:0'),
        scope: ["openid", "profile", "email", "offline_access"],
      )
    );

    await _manager?.init();
    print("oidc: init complete");

    final user = await _manager?.refreshToken();
    if (user == null) {
      print("oidc: refresh failed -> perform login");
      await login();
    } else {
      print("oidc: refresh successful");
      _currentUser.value = user;
      _initialized.value = true;
    }
    
    _manager?.userChanges().listen((user) async {
      print('currentUser changed to ${user?.uid} ${user?.parsedIdToken.claims.toString()}');
      _currentUser.value = user;
      _initialized.value = true;
    });
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

    Object? err;
    try {
      final response = await dio.get('/auth/login');
      print("*** login response");
      print(response);
      if (response.statusCode == 200) {
        _noAuth.value = true;
        _initialized.value = true;
      } else {
        await launchUrl(Uri.parse('${settingsController.serverUrl.value}/auth/login?' 
          'redirect=true&to=${Uri.encodeFull(Uri.base.toString())}'),
          webOnlyWindowName: '_self');
      }
    } catch (error) {
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
    } catch (err) {
      Get.snackbar('Connection failed', 'Failed to connect to server',
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
    print("oidc: logout complete");
  }

  Future<void> refreshTokenIfNeeded() async {
    if (_manager?.currentUser?.token.isAccessTokenAboutToExpire() ?? false) {
      await _manager?.refreshToken();
    }
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
}