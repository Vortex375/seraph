
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:get_storage/get_storage.dart';
import 'package:path_provider/path_provider.dart';

class SettingsController extends GetxController {

  late GetStorage _box;
  
  // settings

  static const _keyThemeMode = 'themeMode';
  late Rx<ThemeMode> _themeMode;

  static const _keyServerUrl = 'serverUrl';
  late Rx<String> _serverUrl;

  static const _keyServerUrlConfirmed = 'serverUrlConfirmed';
  late Rx<bool> _serverUrlConfirmed;

  static const _keyFileBrowserViewMode = 'fileBrowserViewMode';
  late Rx<String> _fileBrowserViewMode;

  static const _keyOidcIssuer = 'oidcIssuer';
  late Rx<String?> _oidcIssuer;

  static const _keyOidcClientId = 'oidcClientId';
  late Rx<String?> _oidcClientId;

  // getters

  Rx<ThemeMode> get themeMode => _themeMode;
  Rx<String> get serverUrl => _serverUrl;
  Rx<bool> get serverUrlConfirmed => _serverUrlConfirmed;
  Rx<String> get fileBrowserViewMode => _fileBrowserViewMode;
  Rx<String?> get oidcIssuer => _oidcIssuer;
  Rx<String?> get oidcClientId => _oidcClientId;

   Future<void> init() async {
    _box = GetStorage('SeraphSettings', kIsWeb ? null : (await getApplicationSupportDirectory()).path);
    await _box.initStorage;

    _themeMode = ThemeMode.values.byName(_box.read(_keyThemeMode) ?? ThemeMode.system.name).obs;
    _fileBrowserViewMode = Rx<String>(_box.read(_keyFileBrowserViewMode) ?? 'list');
    if (kIsWeb) {
      if (kDebugMode) {
        _serverUrl = 'http://localhost:8080'.obs;
      } else {
        //TODO: support context path!?
        _serverUrl = Uri.base.replace(path: '').removeFragment().toString().obs;
      }
      _serverUrlConfirmed = true.obs;
      _oidcIssuer = null.obs;
      _oidcClientId = null.obs;
    } else {
      _serverUrl = Rx<String>(_box.read(_keyServerUrl) ?? '');
      _serverUrlConfirmed = Rx<bool>(_box.read(_keyServerUrlConfirmed) ?? false);
      _oidcIssuer = Rx<String?>(_box.read(_keyOidcIssuer));
      _oidcClientId = Rx<String?>(_box.read(_keyOidcClientId));
    }
  }

  void setThemeMode(ThemeMode value) {
    print('set theme mode: $value');
    _themeMode.value = value;
    _box.write(_keyThemeMode, value.name);
  }

  void setServerUrl(String value) {
    print('set server url: $value');
    _serverUrl.value = value;
    _box.write(_keyServerUrl, value);
  }

  void setServerUrlConfirmed(bool value) {
    print('set server url confirmed: $value');
    if (_serverUrlConfirmed.value != value) {
      // reset the oidc issuer
      setOidc(null, null);
    }
    _serverUrlConfirmed.value = value;
    _box.write(_keyServerUrlConfirmed, value);
  }

  void setFileBrowserViewMode(String value) {
    print('set file browser view mode: $value');
    _fileBrowserViewMode.value = value;
    _box.write(_keyFileBrowserViewMode, value);
  }

  void setOidc(String? issuer, String? clientId) {
    print('set oidc issuer: $issuer');
    print('set oidc client id: $clientId');
    _oidcClientId.value = clientId;
    _oidcIssuer.value = issuer;
    _box.write(_keyOidcIssuer, issuer);
    _box.write(_keyOidcClientId, clientId);
  }
}