import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_breadcrumb/flutter_breadcrumb.dart';
import 'package:go_router/go_router.dart';
import 'package:seraph_app/src/app_bar/app_bar.dart';
import 'package:seraph_app/src/file_browser/file_browser_grid_view.dart';
import 'package:seraph_app/src/file_browser/file_browser_list_view.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/file_browser/selection_controller.dart';
import 'package:webdav_client/webdav_client.dart';

import '../login/login_service.dart';
import '../settings/settings_controller.dart';

class FileBrowser extends StatefulWidget {
  const FileBrowser({
    super.key, 
    required this.settings, 
    required this.loginService, 
    required this.fileService, 
    required this.path
  });

  static const routeName = '/files';

  final SettingsController settings;
  final FileService fileService;
  final LoginService loginService;
  final String path;

  @override
  createState() => _FileBrowserState();
}

class _FileBrowserState extends State<FileBrowser> {
  
  late SelectionController _selectionController;
  late ScrollController _scrollController;
  late String _path;
  late List<File> _items;
  bool _refreshing = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _selectionController = SelectionController(scrollController: _scrollController);
    _path = widget.path.endsWith('/') ? widget.path.substring(0, widget.path.length - 1) : widget.path;
    _items = [];
    _selectionController.clearSelection();
    _refreshing = false;
    loadFiles();
  }

   @override
   void didUpdateWidget(FileBrowser old) {
    super.didUpdateWidget(old);
    if (widget.path != _path) {
      _path = widget.path.endsWith('/') ? widget.path.substring(0, widget.path.length - 1) : widget.path;
      loadFiles();
    }
   }

  Future<void> loadFiles() async {
    setState(() {
      _loading = true;
    });
    
    List<File> files;
    try {
      print("Loading $_path");
      files = await widget.fileService.readDir(_path);
      files.sort((a, b) {
        var aIsDir = a.isDir ?? false;
        var bIsDir = b.isDir ?? false;
        var aName = a.name ?? "";
        var bName = b.name ?? "";
        if (aIsDir && !bIsDir) {
          return -1;
        } else if (bIsDir && !aIsDir) {
          return 1;
        } else {
          return aName.compareTo(bName);
        }
      });
    } catch (err) {
      _refreshing = false;
      _loading = false;
      showError("Load failed: ${err.toString()}");
      print("Error: $err");
      return;
    }
    setState(() {
      _loading = false;
      _items = files;
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
    if (!_loading && (item.isDir ?? false)) {
      GoRouter.of(context).replace('${FileBrowser.routeName}?path=$_path/${item.name}');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("${item.name} Selected"),
      ));
    }
  }

  void clearSelection() {
    _selectionController.clearSelection();
  }

  Widget guardSelection(BuildContext context, Widget body) {
    if (_selectionController.isSelecting) {
      return PopScope(
        canPop: false,
        child: body
      );
    }
    return body;
  }

  List<BreadCrumbItem> _breadCrumbItems() {
    var split = _path.split("/");
    List<BreadCrumbItem> ret = [];
    for (var i = 0; i < split.length; i++) {
      final index = i;
      ret.add(BreadCrumbItem(
        content: Padding(
          padding: const EdgeInsets.all(8),
          child: split[i] == '' ? const Icon(Icons.home) : Text(split[i])
        ), 
        onTap: () {
          var newPath = split.sublist(0, index + 1).join('/');
          if (newPath == '') {
            newPath = '/';
          }
          GoRouter.of(context).replace('${FileBrowser.routeName}?path=$newPath');
        }
      ));
    }
    return ret;
  }

  @override
  Widget build(BuildContext context) {
    
    final List<Widget> bottoms = [];
    bottoms.add(BreadCrumb(
      items: _breadCrumbItems(),
      divider: const Icon(Icons.chevron_right),
      overflow: ScrollableOverflow(
        reverse: true
      ),
      ));

  if (_loading) {
    bottoms.add(const LinearProgressIndicator());
  } else {
    bottoms.add(const SizedBox(height: 4));
  }

    return ListenableBuilder(
      listenable: _selectionController,
      builder: (context, _) {
        return guardSelection(context, Scaffold(
          appBar: _selectionController.isSelecting
              ? AppBar(
                backgroundColor: Theme.of(context).primaryColor,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
                title: Text('${_selectionController.numSelected} Selected'),
                leading: IconButton(onPressed: clearSelection, icon: const Icon(Icons.cancel)),
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.start,
                    mainAxisSize: MainAxisSize.max,
                    children: bottoms,
                  ),
                ),
              )
              : seraphAppBar(context, 
                name: 'Cloud Files', 
                routeName: FileBrowser.routeName, 
                actions: [
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: () {
                      _refreshing = true;
                      loadFiles();
                    },
                  ),
                  IconButton(
                    icon: Icon(widget.settings.fileBrowserViewMode == 'grid' ? Icons.list : Icons.grid_view),
                    onPressed: () {
                      widget.settings.updateFileBrowserViewMode(widget.settings.fileBrowserViewMode == 'grid' ? 'list' : 'grid');
                    },
                  ),
                ],
                bottom: PreferredSize(
                  preferredSize: const Size.fromHeight(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.start,
                    mainAxisSize: MainAxisSize.max,
                    children: bottoms,
                  ),
                )
              ),
        
          
          body: widget.settings.fileBrowserViewMode == 'grid' 
          ? FileBrowserGridView(
            fileService: widget.fileService,
            scrollController: _scrollController,
            selectionController: _selectionController,
            items: _items,
            onOpen: openItem,
          )
          : FileBrowserListView(
            fileService: widget.fileService,
            scrollController: _scrollController,
            selectionController: _selectionController,
            items: _items,
            onOpen: openItem,
          ),
        ));
      }
    );
  }
}
