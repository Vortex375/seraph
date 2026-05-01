import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/app_bar/app_bar.dart';
import 'package:seraph_app/src/spaces_admin/spaces_detail_view.dart';
import 'package:seraph_app/src/spaces_admin/spaces_list_controller.dart';

class SpacesListView extends StatelessWidget {
  const SpacesListView({super.key});

  static const routeName = '/spaces-admin';

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<SpacesListController>();

    return Scaffold(
      appBar: seraphAppBar(
        context,
        name: 'Spaces Admin',
        routeName: routeName,
      ),
      body: Obx(() {
        if (controller.isLoading.value && controller.spaces.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }

        if (controller.spaces.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('No spaces yet'),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => _navigateToDetail(context, null),
                  icon: const Icon(Icons.add),
                  label: const Text('Create Space'),
                ),
              ],
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: controller.loadSpaces,
          child: ListView.builder(
            itemCount: controller.spaces.length,
            itemBuilder: (context, index) {
              final space = controller.spaces[index];
              return Dismissible(
                key: Key(space.id ?? '$index'),
                direction: DismissDirection.endToStart,
                confirmDismiss: (direction) async {
                  return await Get.dialog<bool>(
                    AlertDialog(
                      title: const Text('Delete Space'),
                      content: Text('Delete "${space.title}"?'),
                      actions: [
                        TextButton(
                          onPressed: () => Get.back(result: false),
                          child: const Text('Cancel'),
                        ),
                        FilledButton(
                          onPressed: () => Get.back(result: true),
                          child: const Text('Delete'),
                        ),
                      ],
                    ),
                  );
                },
                onDismissed: (_) => controller.deleteSpace(space.id!),
                background: Container(
                  color: Theme.of(context).colorScheme.error,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 16),
                  child: const Icon(Icons.delete, color: Colors.white),
                ),
                child: Card(
                  margin: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: ListTile(
                    title: Text(space.title),
                    subtitle: Text(
                      space.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('${space.users.length} users'),
                        Text('${space.fileProviders.length} providers'),
                      ],
                    ),
                    onTap: () => _navigateToDetail(context, space.id),
                  ),
                ),
              );
            },
          ),
        );
      }),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _navigateToDetail(context, null),
        child: const Icon(Icons.add),
      ),
    );
  }

  void _navigateToDetail(BuildContext context, String? spaceId) {
    Get.to(() => SpacesDetailView(spaceId: spaceId))?.then((_) {
      Get.find<SpacesListController>().loadSpaces();
    });
  }
}
