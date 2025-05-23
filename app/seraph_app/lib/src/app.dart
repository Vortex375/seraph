import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_browser_controller.dart';
import 'package:seraph_app/src/file_browser/file_browser_view.dart';
import 'package:seraph_app/src/file_viewer/file_viewer_controller.dart';
import 'package:seraph_app/src/file_viewer/file_viewer_view.dart';
import 'package:seraph_app/src/gallery/gallery_view.dart';
import 'package:seraph_app/src/initial_binding.dart';
import 'package:seraph_app/src/media_player/audio_player_view.dart';
import 'package:seraph_app/src/media_player/video_player_controller.dart';
import 'package:seraph_app/src/search/search_controller.dart';
import 'package:seraph_app/src/search/search_view.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/share/share_controller.dart';
import 'package:seraph_app/src/share/share_view.dart';

import 'login/login_view.dart';
import 'settings/settings_view.dart';

/// The Widget that configures your application.
class MyApp extends StatelessWidget {
  const MyApp({
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final ShareController shareController = Get.find();

    List<GetPage<dynamic>> pages;
    if (shareController.shareMode.value) {
      pages = [
        GetPage(
          name: ShareController.routeName,
          page: () {
            if (shareController.isDir.value) {
              Get.find<FileBrowserController>().setPath(Get.parameters['path'] ?? '/');
            }
            return const ShareView();
          },
          transition: Transition.noTransition,
          binding: BindingsBuilder(() {
            Get.put(FileViewerController(), tag: 'shareview');
          })
        ),
        GetPage(
          name: FileViewerView.routeName, 
          page: () => const FileViewerView(),
          binding: BindingsBuilder(() {
            Get.put(FileViewerController());
          })
        ),
        GetPage(
          name: AudioPlayerView.routeName, 
          page: () => const AudioPlayerView(),
          opaque: false,
          transition: Transition.downToUp
        ),
      ];
    } else {
      pages = [
        GetPage(
          name: FileBrowserView.routeName,
          page: () {
            Get.find<FileBrowserController>().setPath(Get.parameters['path'] ?? '/');
            return const LoginView(
              child: FileBrowserView()
            );
          }, 
          transition: Transition.noTransition,
        ),
        GetPage(
          name: GalleryView.routeName, 
          page: () => const GalleryView()
        ),
        GetPage(
          name: FileViewerView.routeName, 
          page: () => const FileViewerView(),
          binding: BindingsBuilder(() {
            Get.put(FileViewerController());
            Get.put(VideoPlayerController());
          })
        ),
        GetPage(
          name: AudioPlayerView.routeName, 
          page: () => const AudioPlayerView(),
          opaque: false,
          transition: Transition.downToUp
        ),
        GetPage(
          name: SearchView.routeName, 
          page: () => const SearchView(),
          binding: BindingsBuilder(() {
            Get.put(MySearchController(Get.find()));
          })
        ),
        GetPage(
          name: SettingsView.routeName, 
          page: () => const SettingsView()
        )
      ];
    }

    final SettingsController settingsController = Get.find();
    return Obx(() => GetMaterialApp(
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
      themeMode: settingsController.themeMode.value,

      initialRoute: shareController.shareMode.value ? ShareController.routeName : FileBrowserView.routeName,
      getPages: pages,
      initialBinding: InitialBinding(),
    ));
  }
}
