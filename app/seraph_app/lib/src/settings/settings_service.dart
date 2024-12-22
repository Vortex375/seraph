import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsService {

  static const keyThemeMode = 'theme_mode'; 
  static const keyServerUrl = 'server_url'; 
  static const keyServerUrlConfirmed = 'server_url_confirmed'; 

  Future<ThemeMode> themeMode() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    var themeMode = prefs.getString(keyThemeMode);
    if (themeMode != null) {
      for (final m in ThemeMode.values) {
        if (m.toString() == themeMode) {
          return m;
        }
      }
    }
    return ThemeMode.system;
  }

  Future<void> updateThemeMode(ThemeMode theme) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyThemeMode, theme.toString());
  }

  Future<String> serverUrl() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getString(keyServerUrl) ?? '';
  }

  Future<void> updateServerUrl(String serverUrl) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(keyServerUrl, serverUrl);
  }

  Future<bool> serverUrlConfirmed() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyServerUrlConfirmed) ?? false;
  }

  Future<void> setServerUrlConfirmed(bool confirmed) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyServerUrlConfirmed, confirmed);
  }
}
