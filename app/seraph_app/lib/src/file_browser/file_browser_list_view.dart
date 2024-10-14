import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:go_router/go_router.dart';
import 'package:seraph_app/src/app_bar/app_bar.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:webdav_client/webdav_client.dart';

import '../settings/settings_controller.dart';
import '../settings/settings_view.dart';

class FileBrowserListView extends StatefulWidget {
  FileBrowserListView({super.key, required this.settings, required this.path})
      : fileService = FileService(settings.serverUrl);

  static const routeName = '/files';

  final SettingsController settings;
  final FileService fileService;
  final String path;

  @override
  createState() => _FileBrowserListViewState();
}

class _FileBrowserListViewState extends State<FileBrowserListView> {
  
  late String _path;
  late List<File> _items;

  @override
  void initState() {
    super.initState();
    _path = widget.path.endsWith('/') ? widget.path : '${widget.path}/';
    _items = [];
    loadFiles();
  }

   @override
   void didUpdateWidget(FileBrowserListView old) {
    super.didUpdateWidget(old);
    if (widget.path != _path) {
      _path = widget.path;
      loadFiles();
    }
   }

  Future<void> loadFiles() async {
    List<File> files;
    try {
      files = await widget.fileService.readDir(_path);
    } catch (err) {
      showError("Load failed: ${err.toString()}");
      return;
    }
    setState(() {
      if (_path == '/') {
        _items = files;
      } else {
        _items = [File(name: '..', isDir: true), ...files];
      }
    });
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
  Widget build(BuildContext context) {
    return Scaffold(
      appBar:
          seraphAppBar(context, 'Cloud Files', FileBrowserListView.routeName, [
        IconButton(
          icon: const Icon(Icons.settings),
          onPressed: () {
            GoRouter.of(context).push(SettingsView.routeName);
          },
        ),
      ]),

      // To work with lists that may contain a large number of items, it’s best
      // to use the ListView.builder constructor.
      //
      // In contrast to the default ListView constructor, which requires
      // building all Widgets up front, the ListView.builder constructor lazily
      // builds Widgets as they’re scrolled into view.
      body: ListView.builder(
        // Providing a restorationId allows the ListView to restore the
        // scroll position when a user leaves and returns to the app after it
        // has been killed while running in the background.
        restorationId: 'sampleItemListView',
        itemCount: _items.length,
        itemBuilder: (BuildContext context, int index) {
          final item = _items[index];

          return ListTile(
              title: Text('${item.name}'),
              leading: const CircleAvatar(
                // Display the Flutter Logo image asset.
                foregroundImage: AssetImage('assets/images/flutter_logo.png'),
              ),
              onTap: () {
                if (item.isDir ?? false) {
                  if (item.name == '..') {
                    var parent = _path.substring(0, _path.lastIndexOf('/'));
                    if (parent == '') {
                      parent = '/';
                    }
                    GoRouter.of(context).replace('${FileBrowserListView.routeName}?path=$parent');
                  } else {
                  GoRouter.of(context).replace('${FileBrowserListView.routeName}?path=$_path${item.name}');
                  }
                }
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text("${item.name} Selected"),
                ));
              });
        },
      ),
    );
  }
}
