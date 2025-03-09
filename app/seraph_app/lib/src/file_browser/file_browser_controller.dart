
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_browser_view.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/file_viewer/file_viewer_view.dart';
import 'package:webdav_client/webdav_client.dart';

class FileBrowserController extends GetxController {
  
  final Rx<List<File>> _files = Rx([]);
  final Rx<RxStatus> _status = RxStatus.empty().obs;
  final Rx<String> _path = ''.obs;
  final RxInt _openItemIndex = RxInt(-1);

  Rx<List<File>> get files => _files;
  Rx<RxStatus> get status => _status;
  Rx<String> get path => _path;
  RxInt get openItemIndex => _openItemIndex;

  bool _first = true;

  Widget Function()? _previewFactory; 

  void setPath(String path) {
    scheduleMicrotask(() {
      var currentPath = _path.value;
      path = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
      _path.value = path;
      if (path != currentPath || _first) {
        _first = false;
        loadFiles();
      }
    });
  }

  void goUp() {
    var split = _path.split("/");
    if (split.length <= 1) {
      setPath('');
    } else {
      setPath(split.sublist(0, split.length - 1).join('/'));
    }
  }

  Future<void> loadFiles() async {
    final FileService fileService = Get.find();
    
    _status.value = RxStatus.loading();
    
    List<File> files;
    try {
      print("Loading $_path");
      files = await fileService.readDir(_path.value);
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
      _files.value = files;
      _status.value = files.isEmpty ? RxStatus.empty() : RxStatus.success();
    } catch (err) {
      _showError(err.toString());
      print("Error: $err");
      _status.value = RxStatus.error();
    }
  }

  void openItem(File item) {
    if (!_status.value.isLoading && (item.isDir ?? false)) {
      Get.offNamed('${FileBrowserView.routeName}?path=$_path/${item.name}');
    } else {
      _openItemIndex.value = files.value.indexOf(item);
      Get.toNamed('${FileViewerView.routeName}?file=$_path/${item.name}');
    }
  }

  void setPreviewWidgetFactory(Widget Function()? factory) {
    _previewFactory = factory;
  }

  // widget used for Hero transition to file viewer
  Widget? getPreviewWidget() {
    if (_previewFactory == null) {
      return null;
    }
    return _previewFactory!();
  }

  void _showError(String error) {
    Get.snackbar('Load failed', error,
        backgroundColor: Colors.amber[800],
        isDismissible: true
      );
  }
}