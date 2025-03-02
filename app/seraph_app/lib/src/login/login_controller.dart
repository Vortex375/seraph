import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';
import 'package:oidc/oidc.dart';
import 'package:oidc_default_store/oidc_default_store.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';

class LoginController extends GetxController {

  LoginController({required this.secureStorage, required this.settingsController}) {
    _initialized = false.obs;
    _noAuth = false.obs;
    _currentUser = Rx<OidcUser?>(null);
    
    settingsController.serverUrlConfirmed.listenAndPump((confirmed) {
      if (confirmed) {
        init(settingsController.oidcIssuer.value, settingsController.oidcClientId.value);
      }
    });
  }

  final FlutterSecureStorage secureStorage;
  final SettingsController settingsController;

  OidcUserManager? _manager;
  
  late Rx<bool> _initialized;
  late Rx<bool> _noAuth;
  late Rx<OidcUser?> _currentUser;

  Rx<bool> get isInitialized => _initialized;
  Rx<bool> get isNoAuth => _noAuth;
  Rx<OidcUser?> get currentUser => _currentUser;

  Future<void> init(String? oidcIssuer, String? clientId) async {
    if (oidcIssuer == null) {
      _oidcDiscovery();
      return;
    }

    if (_manager != null) {
      _manager?.dispose();
      _manager = null;
    }
    _initialized.value = false;
    _currentUser.value = null;
    
    if (oidcIssuer == '') {
      _noAuth.value = true;
      return;
    }

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
    
    bool first = true;
    _manager?.userChanges().listen((user) async {
      print('currentUser changed to ${user?.uid} ${user?.parsedIdToken.claims.toString()}');
      _currentUser.value = user;
      if (first && user == null) {
        await login();
      } else {
        _initialized.value = true;
      }
      first = false;
    });
  }

  Future<void> _oidcDiscovery() async {
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

}