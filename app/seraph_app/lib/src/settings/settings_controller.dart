import 'package:flutter/material.dart';

import 'settings_service.dart';

class SettingsController with ChangeNotifier {
  SettingsController(this._settingsService);

  final SettingsService _settingsService;

  // settings
  late ThemeMode _themeMode;
  late String _serverUrl;
  bool _serverUrlConfirmed = false;
  late String _fileBrowserViewMode;

  // getters
  ThemeMode get themeMode => _themeMode;
  String get serverUrl => _serverUrl;
  bool get serverUrlConfirmed => _serverUrlConfirmed;
  String get fileBrowserViewMode => _fileBrowserViewMode;

  Future<void> loadSettings() async {
    _themeMode = await _settingsService.themeMode();
    _serverUrl = await _settingsService.serverUrl();
    _serverUrlConfirmed = await _settingsService.serverUrlConfirmed();
    _fileBrowserViewMode = await _settingsService.fileBrowserViewMode();

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

  Future<void> confirmServerUrl(bool confirmed) async {
    print('confirm server url $confirmed');

    _serverUrlConfirmed = confirmed;

    notifyListeners();

    await _settingsService.setServerUrlConfirmed(confirmed);
  }

  Future<void> updateServerUrl(String? serverUrl) async {
    print('set server url $serverUrl');
    if (serverUrl == null) return;

    _serverUrl = serverUrl;
    _serverUrlConfirmed = true;

    notifyListeners();

    await _settingsService.updateServerUrl(serverUrl);
    await _settingsService.setServerUrlConfirmed(true);
  }

  Future<void> updateFileBrowserViewMode(String? viewMode) async {
    if (viewMode == null) return;

    _fileBrowserViewMode = viewMode;

    notifyListeners();

    await _settingsService.updateFileBrowserViewMode(viewMode);
  }
}
