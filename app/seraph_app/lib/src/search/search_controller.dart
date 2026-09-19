
import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_browser_view.dart';
import 'package:seraph_app/src/file_viewer/file_viewer_view.dart';
import 'package:seraph_app/src/search/search_service.dart';
import 'package:webdav_client/webdav_client.dart';

import 'package:path/path.dart' as p;

class MySearchController extends GetxController {

  final SearchService searchService;

  final TextEditingController queryTextController = TextEditingController();
  final RxString queryText = ''.obs;
  final RxList<File> fileResults = RxList();
  final RxBool empty = false.obs;

  final FocusNode searchFieldFocusNode = FocusNode();

  MySearchController(this.searchService);

  @override
  void onInit() {
    super.onInit();
    scheduleMicrotask(() => searchFieldFocusNode.requestFocus());

    debounce(queryText, searchFor);
  }

  Future<void> searchFor(String query) async {
    developer.log("search for: $query", name: 'seraph.search');

    if (query.trim() == "") {
      fileResults.clear();
      empty.value = false;
      return;
    }

    final stream = searchService.search(query.trim());

    bool first = true;
    await for (final obj in stream) {
      if (first) {
        first = false;
        fileResults.clear();
      }
      developer.log("found $obj", name: 'seraph.search');
      if (obj["type"] == "files") {
        final reply = obj["reply"] as Map<String, dynamic>;
        fileResults.add(File(
          path: "${reply["providerId"]}/${reply["path"].toString()}",
          name: p.basename(reply["path"].toString())
        ));
        empty.value = false;
      }
    }
    if (first || fileResults.isEmpty) {
      fileResults.clear();
      empty.value = true;
    }
  }

  void clearSearch() {
    queryTextController.clear();
    queryText.value = '';
  }

  void openResultFile(File file) {
    if (file.path == null || file.path!.isEmpty) {
      return;
    }
    Get.toNamed('${FileViewerView.routeName}?path=${file.path}');
  }

  void openResultFolder(String folderPath) {
    if (folderPath.isEmpty) {
      return;
    }
    Get.toNamed('${FileBrowserView.routeName}?path=$folderPath');
  }
}