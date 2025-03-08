
import 'package:flutter/material.dart';
import 'package:flutter_breadcrumb/flutter_breadcrumb.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/app_bar/app_bar.dart';
import 'package:seraph_app/src/file_browser/file_browser_controller.dart';
import 'package:seraph_app/src/file_browser/file_browser_grid_view.dart';
import 'package:seraph_app/src/file_browser/file_browser_list_view.dart';
import 'package:seraph_app/src/file_browser/selection_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';

class FileBrowserView extends StatelessWidget{

  static const routeName = '/files';
  
  const FileBrowserView({super.key});

  List<BreadCrumbItem> _breadCrumbItems(String path) {
    var split = path.split("/");
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
          Get.offNamed('${FileBrowserView.routeName}?path=$newPath');
        }
      ));
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
                icon: const Icon(Icons.refresh),
                onPressed: controller.loadFiles,
              ),
              IconButton(
                icon: Obx(() => Icon(settings.fileBrowserViewMode.value == 'grid' ? Icons.list : Icons.grid_view)),
                onPressed: () {
                  settings.setFileBrowserViewMode(settings.fileBrowserViewMode.value == 'grid' ? 'list' : 'grid');
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
        
        body: Obx(() => settings.fileBrowserViewMode.value == 'grid' 
          ? FileBrowserGridView(
            fileService: Get.find(),
            selectionController: selectionController,
            items: controller.files.value,
            onOpen: controller.openItem,
          )
          : FileBrowserListView(
            fileService: Get.find(),
            selectionController: selectionController,
            items: controller.files.value,
            onOpen: controller.openItem,
          ),
        )
      ))
    );
  }

}