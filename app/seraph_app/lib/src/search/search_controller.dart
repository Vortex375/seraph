
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
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

  searchFor(String query) async {
    print("search for: $query");

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
      print("found $obj");
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

  clearSearch() {
    queryTextController.clear();
    queryText.value = '';
  }
}