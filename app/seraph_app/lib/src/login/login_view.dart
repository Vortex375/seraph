import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:dio/dio.dart';
import 'package:flutter/scheduler.dart';

import '../settings/settings_controller.dart';

class LoginView extends StatefulWidget {
  const LoginView({super.key, required this.settings, required this.child});

  static const routeName = '/files';

  final SettingsController settings;
  final Widget child;

  @override
  createState() => _LoginViewState();
}

class _LoginViewState extends State<LoginView> {

  bool _loggedIn = false;
  bool _changeServerUrl = false;

  bool _hasServerUrl() {
    // server URL can't be changed on web
   if (kIsWeb) {
    return true;
   }
   // change requested
   if (_changeServerUrl) {
    return false;
   }
   return widget.settings.serverUrl != "";
  }

  Future<void> _doLogin() async {
    final dio = Dio(BaseOptions(baseUrl: widget.settings.serverUrl));
    try {
      final response = await dio.get('/auth/config');
      print(response);
    } catch (err) {
      showError("Failed to connect to server: ${err.toString()}");
      print(err);
      setState(() {
        _changeServerUrl = true;
      });
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
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(listenable: widget.settings, builder: (BuildContext context, Widget? child) {
      if (!_hasServerUrl()) {
        return _serverSelection(context);
      }
      if (!_loggedIn) {
        return _loginState(context);
      }

      return widget.child;
    });
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
                      onSubmitted: (v) {
                        setState(() {
                          _changeServerUrl = false;
                        });
                        widget.settings.updateServerUrl(v);
                      },
                    )
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
    _doLogin();

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
                      setState(() {
                        _changeServerUrl = true;
                      });
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