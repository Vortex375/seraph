import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:dio/dio.dart';
import 'package:flutter/scheduler.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';

import 'login_service.dart';

class LoginView extends StatefulWidget {
  const LoginView({super.key, required this.loginService, required this.child});

  static const routeName = '/files';

  final LoginService loginService;
  final Widget child;

  @override
  createState() => _LoginViewState();
}

class _LoginViewState extends State<LoginView> {

  bool _loggedIn() {
    return widget.loginService.isInitialized && (widget.loginService.isNoAuth || widget.loginService.currentUser != null);
  }

  bool _hasServerUrl() {
    // server URL can't be changed on web
  //  if (kIsWeb) {
  //   return true;
  //  }
   // change requested

  SettingsController settings = Get.find();

   if (!settings.serverUrlConfirmed.value) {
    return false;
   }
   return settings.serverUrl.value != "";
  }

  void _setServerUrl(String url) async {
    SettingsController settings = Get.find();
    await widget.loginService.reset();
    settings.setServerUrl(url);
    settings.setServerUrlConfirmed(true);
    _doLogin();
  }

  Future<void> _doLogin() async {
    SettingsController settings = Get.find();
    final dio = Dio(BaseOptions(baseUrl: settings.serverUrl.value));
    try {
      final response = await dio.get('/auth/config');
      if (response.data['Issuer'] == null) {
        print('no authentication');
        widget.loginService.noAuth();
      } else {
        print('yes authentication');
        await widget.loginService.init(response.data['Issuer'], response.data['AppClientId']);
      }
    } catch (err) {
      showError("Failed to connect to server: ${err.toString()}");
      settings.setServerUrlConfirmed(false);
    }
  }

  void showError(String msg) {
    showErr() {
        ScaffoldMessenger.of(context).showMaterialBanner(MaterialBanner(
          content: Text(msg),
          backgroundColor: Colors.amber[800],
          actions: [
            TextButton(onPressed: () {
              ScaffoldMessenger.of(context).clearMaterialBanners();
            }, child: const Text('DISMISS'))
          ],
        ));
      }
      if (mounted) {
        showErr();
      } else {
        SchedulerBinding.instance.addPostFrameCallback((_) =>showErr());
      }
  }

  @override
  void initState() {
    super.initState();

    if (_hasServerUrl() && ! kIsWeb && !widget.loginService.isInitialized) {
      _doLogin();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.loginService, 
      builder: (BuildContext context, Widget? child) => Obx(() {
        if (!_hasServerUrl()) {
          return _serverSelection(context);
        }
        if (!_loggedIn()) {
          return _loginState(context);
        }
    
        return widget.child;
      })
    );
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
                    FilledButton(onPressed: () {
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