
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:oidc/oidc.dart';
import 'package:oidc_default_store/oidc_default_store.dart';

class LoginService with ChangeNotifier {

  LoginService();

  OidcUserManager? _manager;
  bool _initialized = false;
  bool _noAuth = false;
  OidcUser? _currentUser;

  bool get isInitialized => _initialized;
  bool get isNoAuth => _noAuth;
  OidcUser? get currentUser => _currentUser;

  noAuth() {
    if (_manager != null) {
      _manager?.dispose();
      _manager = null;
    }
    _initialized = true;
    _noAuth = true;
    _currentUser = null;
    notifyListeners();
  }

  Future<void> init(String issuer, String clientId) async {
    if (_manager != null) {
      _manager?.dispose();
      _manager = null;
    }
    _initialized = false;
    _currentUser = null;
    _noAuth = false;
    notifyListeners();

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
          Uri.parse(issuer),
      ),
      clientCredentials: OidcClientAuthentication.none(clientId: clientId),
      store: OidcDefaultStore(),
      settings: OidcUserManagerSettings(
        redirectUri: Platform.isIOS || Platform.isMacOS || Platform.isAndroid 
            ? Uri.parse("net.umbasa.seraph.app:/oaut2redirect")
            : Uri.parse('http://localhost:0')
      ) //TODO: other platforms
    );

    await _manager?.init();
    print("oidc: init complete");
    _initialized = true;
    notifyListeners();

    bool first = true;
    _manager?.userChanges().listen((user) async {
      print('currentUser changed to ${user?.uid} ${user?.parsedIdToken.claims.toString()}');
      _currentUser = user;
      notifyListeners();
      if (first && user == null) {
        await login();
      }
      first = false;
    });
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
    _currentUser = null;
    print("oidc: logout complete");
    notifyListeners();
  }

  Future<void> reset() async {
    if (_manager != null) {
      //TODO: when to do this?
      // await _manager?.forgetUser();
      await _manager?.dispose();
      _manager = null;
    }
    _noAuth = false;
    _initialized = false;
    _currentUser = null;
    notifyListeners();
  }

}
