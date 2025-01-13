import 'package:flutter/material.dart';

import '../app_bar/app_bar.dart';
import 'settings_controller.dart';

/// Displays the various settings that can be customized by the user.
///
/// When a user changes a setting, the SettingsController is updated and
/// Widgets that listen to the SettingsController are rebuilt.
class SettingsView extends StatelessWidget {
  const SettingsView({super.key, required this.settings});

  static const routeName = '/settings';

  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    final urlController = TextEditingController(text: settings.serverUrl);
    return Scaffold(
      appBar: seraphAppBar(context, 
        name: 'Settings', 
        routeName: routeName, 
        actions: []
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Appearance', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 16),
                    DropdownMenu<ThemeMode>(
                      label: const Text('Theme'),
                      initialSelection: settings.themeMode,
                      onSelected: settings.updateThemeMode,
                      requestFocusOnTap: false,
                      dropdownMenuEntries: const [
                        DropdownMenuEntry(
                          value: ThemeMode.system,
                          label: 'System Theme',
                        ),
                        DropdownMenuEntry(
                          value: ThemeMode.light,
                          label: 'Light Theme',
                        ),
                        DropdownMenuEntry(
                          value: ThemeMode.dark,
                          label: 'Dark Theme',
                        )
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Server', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 16),
                    TextField(
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Url',
                      ),
                      controller: urlController,
                      onSubmitted: settings.updateServerUrl,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
