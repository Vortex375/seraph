import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:seraph_app/src/app_providers.dart';
import 'package:seraph_app/src/file_browser/file_browser.dart';
import 'package:go_router/go_router.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/gallery/gallery_view.dart';

import 'login/login_service.dart';
import 'login/login_view.dart';
import 'settings/settings_controller.dart';
import 'settings/settings_view.dart';

/// The Widget that configures your application.
class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
    required this.settingsController,
    required this.loginService,
    required this.fileService
  });

  final SettingsController settingsController;
  final LoginService loginService;
  final FileService fileService;

  @override
  Widget build(BuildContext context) {
    Widget withProviders (child) => AppProviders(
      settingsController: settingsController, 
      loginService: loginService, 
      fileService: fileService, 
      child: child
    );


    final router = GoRouter(
      debugLogDiagnostics: true,
      initialLocation: '/files',
      routes: [
        GoRoute(
          path: FileBrowser.routeName,
          builder: (context, state) => withProviders(LoginView(
            settings: settingsController, 
            loginService: loginService,
            child: FileBrowser(
              settings: settingsController, 
              loginService: loginService,
              fileService: fileService,
              path: state.uri.queryParameters['path'] ?? '/'
            )
          )
        )),
        GoRoute(
          path: GalleryView.routeName,
          builder: (context, state) => withProviders(const GalleryView(),
        )),
        GoRoute(
          path: SettingsView.routeName,
          builder: (context, state) => withProviders(SettingsView(settings: settingsController),
        )),
      ],
    );
    // Glue the SettingsController to the MaterialApp.
    //
    // The ListenableBuilder Widget listens to the SettingsController for changes.
    // Whenever the user updates their settings, the MaterialApp is rebuilt.
    return ListenableBuilder(
      listenable: settingsController,
      builder: (BuildContext context, Widget? child) {
        return MaterialApp.router(
          // Providing a restorationScopeId allows the Navigator built by the
          // MaterialApp to restore the navigation stack when a user leaves and
          // returns to the app after it has been killed while running in the
          // background.
          restorationScopeId: 'app',

          // Provide the generated AppLocalizations to the MaterialApp. This
          // allows descendant Widgets to display the correct translations
          // depending on the user's locale.
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [
            Locale('en', ''), // English, no country code
          ],

          // Use AppLocalizations to configure the correct application title
          // depending on the user's locale.
          //
          // The appTitle is defined in .arb files found in the localization
          // directory.
          onGenerateTitle: (BuildContext context) =>
              AppLocalizations.of(context)!.appTitle,

          // Define a light and dark color theme. Then, read the user's
          // preferred ThemeMode (light, dark, or system default) from the
          // SettingsController to display the correct theme.
          theme: ThemeData(
            useMaterial3: true
          ),
          darkTheme: ThemeData.dark(
            useMaterial3: true
          ),
          themeMode: settingsController.themeMode,

          routerConfig: router,
        );
      },
    );
  }
}
