
import 'package:flutter/material.dart';
import 'package:flutter_breadcrumb/flutter_breadcrumb.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/app_bar/app_bar.dart';
import 'package:seraph_app/src/file_browser/file_browser_controller.dart';
import 'package:seraph_app/src/file_browser/file_browser_grid_view.dart';
import 'package:seraph_app/src/file_browser/file_browser_list_view.dart';
import 'package:seraph_app/src/file_browser/selection_controller.dart';
import 'package:seraph_app/src/media_player/media_bottom_bar.dart';
import 'package:seraph_app/src/search/search_view.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/share/share_controller.dart';

class FileBrowserView extends StatelessWidget {

  static const routeName = '/files';
  
  const FileBrowserView({super.key});

  List<BreadCrumbItem> _breadCrumbItems(String path) {
    final ShareController shareController = Get.find();

    if (!path.startsWith("/")) {
      path = "/$path";
    }

    var split = path.split("/");
    List<BreadCrumbItem> ret = [];
    final start = shareController.shareMode.value ? 1 : 0;
    for (var i = start; i < split.length; i++) {
      if (i != start && split[i] == '') {
        continue;
      }
      final index = i;
      ret.add(BreadCrumbItem(
        content: Padding(
          padding: const EdgeInsets.all(8),
          child: i == start ? const Icon(Icons.home) : Text(split[i])
        ), 
        onTap: () {
          var newPath = split.sublist(0, index + 1).join('/');
          if (newPath == '') {
            newPath = '/';
          }
          Get.offNamed('${shareController.shareMode.value ? ShareController.routeName : FileBrowserView.routeName}?path=$newPath');
        }
      ));
    }

    if (ret.isEmpty) {
      ret.add(BreadCrumbItem(content: Container()));
    }

    return ret;
  }
  
  @override
  Widget build(BuildContext context) {
    SettingsController settings = Get.find();
    FileBrowserController controller = Get.find();
    SelectionController selectionController = Get.find();

    final List<Widget> bottoms = [];
    bottoms.add(Obx(() => SizedBox(
      width: double.infinity,
      child: Align(
        alignment: Alignment.centerLeft,
        child: BreadCrumb(
          items: _breadCrumbItems(controller.path.value),
          divider: const Icon(Icons.chevron_right),
          overflow: ScrollableOverflow(
            reverse: true
          ),
        ),
      ),
    )));

    bottoms.add(Obx(() {
      if (controller.status.value.isLoading) {
        return const LinearProgressIndicator();
      } else {
        return const SizedBox(height: 4);
      }
    }));
    
    return PopScope(
      canPop: false,
      //TODO: replace with goBack()
      onPopInvokedWithResult: (didPop, result) => controller.goUp(),
      child: Obx(() => Scaffold(
        appBar: selectionController.isSelecting.value
          ? AppBar(
            backgroundColor: Theme.of(context).primaryColor,
            foregroundColor: Theme.of(context).colorScheme.onPrimary,
            title: Text('${selectionController.numSelected} Selected'),
            leading: IconButton(onPressed: selectionController.clearSelection, icon: const Icon(Icons.cancel)),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.start,
                mainAxisSize: MainAxisSize.max,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: bottoms,
              ),
            ),
          )
          : seraphAppBar(context, 
            name: 'Cloud Files', 
            routeName: FileBrowserView.routeName, 
            actions: [
              IconButton(
                icon: const Icon(Icons.search),
                tooltip: 'Search',
                onPressed: () {
                  Get.toNamed(SearchView.routeName);
                },
              ),
              Obx(() => IconButton(
                icon: Icon(settings.fileBrowserViewMode.value == 'grid' ? Icons.list : Icons.grid_view),
                tooltip: settings.fileBrowserViewMode.value == 'grid' ? 'List View' : 'Grid View',
                onPressed: () {
                  settings.setFileBrowserViewMode(settings.fileBrowserViewMode.value == 'grid' ? 'list' : 'grid');
                },
              )),
              PopupMenuButton(
                itemBuilder: (builder) => [
                  PopupMenuItem(
                    onTap: controller.loadFiles,
                    child: const Row(
                      children: [
                        Icon(Icons.refresh),
                        Expanded(child: Text('Refresh')),
                      ],
                    )
                  )
                ]
              )
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

        bottomNavigationBar: const MediaBottomBar(),
        
        body: Obx(() => settings.fileBrowserViewMode.value == 'grid'
          ? GestureDetector(
            behavior: HitTestBehavior.translucent,
            onScaleStart: (details) {
              controller.gridViewSizeInitial = controller.gridViewSize.value;
            },
            onScaleUpdate: (details) {
              var size = controller.gridViewSizeInitial * details.scale;
              if (size < 50) {
                size = 50;
              }
              if (size > 500) {
                size = 500;
              }
              controller.gridViewSize(size);
            },
            child: FileBrowserGridView(
              fileService: Get.find(),
              selectionController: selectionController,
              items: controller.files.value,
              gridSize: controller.gridViewSize.value,
            ),
          )
          : FileBrowserListView(
            fileService: Get.find(),
            selectionController: selectionController,
            items: controller.files.value,
          ),
        )
      ))
    );
  }

}