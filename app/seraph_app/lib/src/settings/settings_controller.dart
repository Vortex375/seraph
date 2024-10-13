import 'package:flutter/material.dart';

import 'settings_service.dart';

class SettingsController with ChangeNotifier {
  SettingsController(this._settingsService);

  final SettingsService _settingsService;

  // settings
  late ThemeMode _themeMode;
  late String _serverUrl;

  // getters
  ThemeMode get themeMode => _themeMode;
  String get serverUrl => _serverUrl;

  Future<void> loadSettings() async {
    _themeMode = await _settingsService.themeMode();
    _serverUrl = await _settingsService.serverUrl();

    notifyListeners();
  }

  Future<void> updateThemeMode(ThemeMode? newThemeMode) async {
    print('set theme mode $newThemeMode');
    if (newThemeMode == null) return;
    if (newThemeMode == _themeMode) return;

    _themeMode = newThemeMode;

    notifyListeners();

    await _settingsService.updateThemeMode(newThemeMode);
  }

  Future<void> updateServerUrl(String? serverUrl) async {
    print('set server url $serverUrl');
    if (serverUrl == null) return;
    if (serverUrl == _serverUrl) return;

    _serverUrl = serverUrl;

    notifyListeners();

    await _settingsService.updateServerUrl(serverUrl);
  }
}
