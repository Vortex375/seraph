import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';

class LoginView extends StatelessWidget {
  const LoginView({super.key, required this.child});

  static const routeName = '/files';

  final Widget child;

  bool _loggedIn() {
    LoginController loginController = Get.find();
    return loginController.isInitialized.value && (loginController.isNoAuth.value || loginController.currentUser.value != null);
  }

  bool _hasServerUrl() {
    // server URL can't be changed on web
    if (kIsWeb) {
      return true;
    }

    SettingsController settings = Get.find();

    if (!settings.serverUrlConfirmed.value) {
    return false;
    }
    return settings.serverUrl.value != "";
  }

  void _setServerUrl(String url) async {
    SettingsController settings = Get.find();
    settings.setServerUrl(url);
    settings.setServerUrlConfirmed(true);
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
        if (!_hasServerUrl()) {
          return _serverSelection(context);
        }
        if (!_loggedIn()) {
          return _loginState(context);
        }
    
        return child;
      });
  }

  Widget _serverSelection(BuildContext context) {
    SettingsController settings = Get.find();
    final urlController = TextEditingController(text: settings.serverUrl.value);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Seraph'),
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
                    Text('Log in to server', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 16),
                    TextField(
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Url',
                      ),
                       controller: urlController,
                      onSubmitted: _setServerUrl,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: () {
                      _setServerUrl(urlController.text);
                    }, child: const Text('Connect'))
                  ]
                )
              )
            )
          ]
        )
      )
    );
  }

  Widget _loginState(BuildContext context) {
    SettingsController settings = Get.find();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Seraph'),
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
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text('Connecting to server', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 16),
                    const CircularProgressIndicator(
                      value: null,
                      semanticsLabel: 'Login progress indicator',
                    ),
                    const SizedBox(height: 16),
                    Text(settings.serverUrl.value, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).disabledColor)),
                    const SizedBox(height: 16),
                    if (!kIsWeb) FilledButton(onPressed: () {
                      settings.setServerUrlConfirmed(false);
                    }, child: const Text('Change Server'))
                  ]
                )
              )
            )
          ]
        )
      )
    );
  }
}