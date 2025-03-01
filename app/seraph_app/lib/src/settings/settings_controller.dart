
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

  // getters

  Rx<ThemeMode> get themeMode => _themeMode;
  Rx<String> get serverUrl => _serverUrl;
  Rx<bool> get serverUrlConfirmed => _serverUrlConfirmed;
  Rx<String> get fileBrowserViewMode => _fileBrowserViewMode;

   Future<void> init() async {
    _box = GetStorage('SeraphSettings', (await getApplicationSupportDirectory()).path);
    await _box.initStorage;

    _themeMode = ThemeMode.values.byName(_box.read(_keyThemeMode) ?? ThemeMode.system.name).obs;
    _serverUrl = Rx<String>(_box.read(_keyServerUrl) ?? '');
    _serverUrlConfirmed = Rx<bool>(_box.read(_keyServerUrlConfirmed) ?? false);
    _fileBrowserViewMode = Rx<String>(_box.read(_keyFileBrowserViewMode) ?? 'list');
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
    _serverUrlConfirmed.value = value;
    _box.write(_keyServerUrlConfirmed, value);
  }

  void setFileBrowserViewMode(String value) {
    print('set file browser view mode: $value');
    _fileBrowserViewMode.value = value;
    _box.write(_keyFileBrowserViewMode, value);
  }
}