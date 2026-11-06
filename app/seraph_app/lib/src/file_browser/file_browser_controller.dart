import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_browser_view.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/file_viewer/file_viewer_view.dart';
import 'package:seraph_app/src/media_player/audio_player_controller.dart';
import 'package:seraph_app/src/share/share_controller.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webdav_client/webdav_client.dart';

class FileBrowserController extends GetxController {
  final Rx<List<File>> _files = Rx([]);
  final Rx<RxStatus> _status = RxStatus.empty().obs;
  final Rx<String> _path = ''.obs;
  final RxInt _openItemIndex = RxInt(-1);
  final RxDouble gridViewSize = RxDouble(200);

  double gridViewSizeInitial = 200;

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
      developer.log("Error: $err", name: 'seraph.file_browser', error: err);
      _status.value = RxStatus.error();
    }
  }

  void openItem(File item) {
    final ShareController shareController = Get.find();

    if (!_status.value.isLoading && (item.isDir ?? false)) {
      Get.offNamed(
          '${shareController.shareMode.value ? ShareController.routeName : FileBrowserView.routeName}?path=$_path/${item.name}');
    } else {
      _openItemIndex.value = files.value.indexOf(item);
      Get.toNamed('${FileViewerView.routeName}?path=$_path/${item.name}');
    }
  }

  /// Clears the "which file in the current listing the viewer opened on"
  /// cursor. Opening the file viewer directly - outside the browser, as the
  /// gallery does - must not inherit a stale index from an earlier
  /// in-browser open, or it would show that old listing's file instead of
  /// the one asked for.
  void resetOpenItem() {
    _openItemIndex.value = -1;
  }

  Future<void> download() async {
    final FileService fileService = Get.find();
    if (kIsWeb) {
      await launchUrl(Uri.parse(fileService.getDownloadUrl(_path.value)),
          webOnlyWindowName: '_blank');
    }
  }

  /// Sends [items] to the player's queue: an audio file directly, a folder
  /// through one non-recursive listing of its own audio files in name order.
  /// Non-audio files are ignored.
  Future<void> enqueue(List<File> items, {required bool playNext}) async {
    final fileService = Get.find<FileService>();
    final player = Get.find<AudioPlayerController>();
    final paths = <String>[];
    var sawFolder = false;

    for (final item in items) {
      if (item.isDir ?? false) {
        sawFolder = true;
        final path = item.path;
        if (path == null) {
          continue;
        }
        try {
          final children = await fileService.readDir(path);
          final audio = children.where(fileService.isAudioFile).toList()
            ..sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));
          paths.addAll(audio
              .map((f) => f.path)
              .whereType<String>()
              .where((p) => p.isNotEmpty));
        } catch (err) {
          developer.log("Error reading folder $path: $err",
              name: 'seraph.file_browser', error: err);
        }
      } else if (fileService.isAudioFile(item) && item.path != null) {
        paths.add(item.path!);
      }
    }

    if (paths.isEmpty) {
      Get.snackbar('Nothing added',
          sawFolder ? 'The folder has no audio files' : 'No audio files selected',
          backgroundColor: Colors.amber[800], isDismissible: true);
      return;
    }

    await player.enqueue(paths, playNext: playNext);
    Get.snackbar(
        playNext ? 'Play next' : 'Added to queue',
        paths.length == 1 ? '1 track added' : '${paths.length} tracks added',
        isDismissible: true);
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
        backgroundColor: Colors.amber[800], isDismissible: true);
  }
}
