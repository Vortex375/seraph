import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:dio/dio.dart';
import 'package:flutter/scheduler.dart';

import '../settings/settings_controller.dart';
import 'login_service.dart';

class LoginView extends StatefulWidget {
  const LoginView({super.key, required this.settings, required this.loginService, required this.child});

  static const routeName = '/files';

  final SettingsController settings;
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
   if (kIsWeb) {
    return true;
   }
   // change requested
   if (!widget.settings.serverUrlConfirmed) {
    return false;
   }
   return widget.settings.serverUrl != "";
  }

  void _setServerUrl(String url) async {
    await widget.loginService.reset();
    await widget.settings.updateServerUrl(url);
    _doLogin();
  }

  Future<void> _doLogin() async {
    final dio = Dio(BaseOptions(baseUrl: widget.settings.serverUrl));
    try {
      final response = await dio.get('/auth/config');
      if (response.data['Issuer'] == null) {
        print('no authentication');
      } else {
        print('yes authentication');
        await widget.loginService.init(response.data['Issuer'], response.data['AppClientId']);
      }
    } catch (err) {
      showError("Failed to connect to server: ${err.toString()}");
      await widget.settings.confirmServerUrl(false);
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
      listenable: Listenable.merge([widget.settings, widget.loginService]), 
      builder: (BuildContext context, Widget? child) {
        if (!_hasServerUrl()) {
          return _serverSelection(context);
        }
        if (!_loggedIn()) {
          return _loginState(context);
        }

        return widget.child;
      }
    );
  }

  Widget _serverSelection(BuildContext context) {
    final urlController = TextEditingController(text: widget.settings.serverUrl);
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
                    Text(widget.settings.serverUrl, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).disabledColor)),
                    const SizedBox(height: 16),
                    FilledButton(onPressed: () {
                      widget.settings.confirmServerUrl(false);
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