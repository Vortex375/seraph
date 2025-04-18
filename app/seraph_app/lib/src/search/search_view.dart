
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/search/search_controller.dart';

class SearchView extends StatelessWidget {
  
  static const routeName = '/search';

  const SearchView({super.key});

  @override
  Widget build(BuildContext context) {
    final MySearchController controller = Get.find();

    return Obx(() => Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: controller.queryTextController,
          focusNode: controller.searchFieldFocusNode,
          onChanged: controller.queryText.call,
          decoration: const InputDecoration(
            hintText: 'Search...',
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (controller.queryText.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: controller.clearSearch,
            ),
        ],
      ),
      body: controller.empty.value ? const Center(child: Column(spacing: 8, children: [Icon(Icons.not_interested, size: 48), Text("no results")])) : ListView.builder(
        itemCount: controller.fileResults.length,
        itemBuilder: (BuildContext context, int index) {
          final item = controller.fileResults[index];

          return ListTile(
            title: Text(item.name ?? '')
          );
        }),
    ));
  }

}