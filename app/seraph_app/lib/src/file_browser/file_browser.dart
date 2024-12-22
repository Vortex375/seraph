import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:go_router/go_router.dart';
import 'package:seraph_app/src/app_bar/app_bar.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:webdav_client/webdav_client.dart';

import '../login/login_service.dart';
import '../settings/settings_controller.dart';

class FileBrowser extends StatefulWidget {
  FileBrowser({super.key, required this.settings, required this.loginService, required this.path})
      : fileService = FileService(settings.serverUrl, loginService);

  static const routeName = '/files';

  final SettingsController settings;
  final FileService fileService;
  final LoginService loginService;
  final String path;

  @override
  createState() => _FileBrowserState();
}

class _FileBrowserState extends State<FileBrowser> {
  
  late String _path;
  late List<File> _items;
  late Set<String> _selectedItems;
  late bool _refreshing;

  get isSelecting => _selectedItems.isNotEmpty;
  get numSelected => _selectedItems.length;

  @override
  void initState() {
    super.initState();
    _path = widget.path.endsWith('/') ? widget.path : '${widget.path}/';
    _items = [];
    _selectedItems = {};
    _refreshing = false;
    loadFiles();
  }

   @override
   void didUpdateWidget(FileBrowser old) {
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
      _refreshing = false;
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
    if (_refreshing && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('List refreshed'),
        duration: Durations.extralong4,
      ));
    }
    _refreshing = false;
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

  void openItem(File item) {
    if (item.isDir ?? false) {
      if (item.name == '..') {
        var parent = _path.substring(0, _path.lastIndexOf('/'));
        if (parent == '') {
          parent = '/';
        }
        GoRouter.of(context).replace('${FileBrowser.routeName}?path=$parent');
      } else {
      GoRouter.of(context).replace('${FileBrowser.routeName}?path=$_path${item.name}');
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text("${item.name} Selected"),
    ));
  }

  void selectItem(File item, bool selected) {
    setState(() {
      final path = item.path;
      if (selected && path != null) {
        _selectedItems.add(path);
      } else {
        _selectedItems.remove(path);
      }
    });
  }

  void clearSelection() {
    setState(() {
      _selectedItems = {};
    });
  }

  Widget guardSelection(BuildContext context, Widget body) {
    if (isSelecting) {
      return PopScope(
        canPop: false,
        child: body
      );
    }
    return body;
  }

  @override
  Widget build(BuildContext context) {
    return guardSelection(context, Scaffold(
      appBar: isSelecting
          ? AppBar(
            backgroundColor: Theme.of(context).primaryColor,
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
            title: Text('$numSelected Selected'),
            leading: IconButton(onPressed: clearSelection, icon: const Icon(Icons.cancel)),
          )
          : seraphAppBar(context, 'Cloud Files', FileBrowser.routeName, [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                _refreshing = true;
                loadFiles();
              },
            ),
            IconButton(
              icon: const Icon(Icons.logout),
              onPressed: () {
                widget.settings.confirmServerUrl(false);
                widget.loginService.logout();
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
          final selected = _selectedItems.contains(item.path);

          return ListTile(
              title: Text('${item.name}'),
              leading: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isSelecting) Checkbox(
                    value: selected, 
                    onChanged: (v) => selectItem(item, v ?? false)
                  ),
                  if (isSelecting) const SizedBox(width: 4),
                  Image.network("${widget.settings.serverUrl}/preview?p=foo${item.path}&w=256&h=256&exact=false"),
                ],
              ),
              onTap: () => openItem(item),
              onLongPress: () => selectItem(item, ! selected),
            );
        },
      ),
    ));
  }
}
