import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/app_bar/app_bar.dart';
import 'package:seraph_app/src/spaces_admin/provider_picker_dialog.dart';
import 'package:seraph_app/src/spaces_admin/spaces_detail_controller.dart';
import 'package:seraph_app/src/spaces_admin/spaces_list_view.dart';
import 'package:seraph_app/src/spaces_admin/spaces_models.dart';
import 'package:seraph_app/src/spaces_admin/spaces_service.dart';

class SpacesDetailView extends StatefulWidget {
  const SpacesDetailView({super.key, this.spaceId});

  final String? spaceId;

  @override
  State<SpacesDetailView> createState() => _SpacesDetailViewState();
}

class _SpacesDetailViewState extends State<SpacesDetailView> {
  String get _tag => 'detail-${widget.spaceId ?? 'new'}';

  @override
  void initState() {
    super.initState();
    final spacesService = Get.find<SpacesService>();
    Get.put(
      SpacesDetailController(spacesService, spaceId: widget.spaceId),
      tag: _tag,
    );
  }

  @override
  void dispose() {
    Get.delete<SpacesDetailController>(tag: _tag, force: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<SpacesDetailController>(tag: _tag);

    return Scaffold(
      appBar: seraphAppBar(
        context,
        name: controller.isEditing ? 'Edit Space' : 'New Space',
        routeName: SpacesListView.routeName,
        actions: [
          if (controller.isEditing)
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () => _confirmDelete(controller),
            ),
        ],
      ),
      body: Obx(() {
        if (controller.isLoading.value) {
          return const Center(child: CircularProgressIndicator());
        }

        if (controller.error.value != null) {
          return Center(child: Text(controller.error.value!));
        }

        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTitleSection(controller),
              const SizedBox(height: 16),
              _buildUsersSection(controller),
              const SizedBox(height: 16),
              _buildProvidersSection(controller),
              const SizedBox(height: 24),
              _buildSaveButton(controller),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildTitleSection(SpacesDetailController controller) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Details',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: controller.titleController,
              decoration: const InputDecoration(
                labelText: 'Title *',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller.descriptionController,
              decoration: const InputDecoration(
                labelText: 'Description',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUsersSection(SpacesDetailController controller) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Users',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller.userInputController,
                    decoration: const InputDecoration(
                      labelText: 'User ID',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => controller.addUser(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: controller.addUser,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Obx(() => Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: controller.users
                      .map((user) => Chip(
                            label: Text(user),
                            onDeleted: () => controller.removeUser(user),
                          ))
                      .toList(),
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildProvidersSection(SpacesDetailController controller) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('File Providers',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Obx(() => ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: controller.fileProviders.length,
                  itemBuilder: (context, index) {
                    final fp = controller.fileProviders[index];
                    return _buildProviderCard(controller, index, fp);
                  },
                )),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _addProvider(controller),
              icon: const Icon(Icons.add),
              label: const Text('Add Provider'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProviderCard(
    SpacesDetailController controller,
    int index,
    SpaceFileProvider fp,
  ) {
    final nameCtrl =
        TextEditingController(text: fp.spaceProviderId);
    final pathCtrl = TextEditingController(text: fp.path);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    fp.providerId,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .colorScheme
                              .onSurfaceVariant,
                        ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () =>
                      controller.removeFileProvider(index),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Display Name',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) {
                controller.updateFileProvider(
                  index,
                  SpaceFileProvider(
                    spaceProviderId: v,
                    providerId: fp.providerId,
                    path: pathCtrl.text,
                    readOnly: fp.readOnly,
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            TextField(
              controller: pathCtrl,
              decoration: const InputDecoration(
                labelText: 'Path',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) {
                controller.updateFileProvider(
                  index,
                  SpaceFileProvider(
                    spaceProviderId: nameCtrl.text,
                    providerId: fp.providerId,
                    path: v,
                    readOnly: fp.readOnly,
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              title: const Text('Read Only'),
              value: fp.readOnly,
              onChanged: (v) {
                controller.updateFileProvider(
                  index,
                  SpaceFileProvider(
                    spaceProviderId: nameCtrl.text,
                    providerId: fp.providerId,
                    path: pathCtrl.text,
                    readOnly: v,
                  ),
                );
              },
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSaveButton(SpacesDetailController controller) {
    return Obx(() => FilledButton(
          onPressed: controller.isSaving.value
              ? null
              : () => _save(controller),
          child: controller.isSaving.value
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ));
  }

  Future<void> _save(SpacesDetailController controller) async {
    final success = await controller.save();
    if (success && mounted) {
      Get.back();
    }
  }

  Future<void> _addProvider(SpacesDetailController controller) async {
    final result = await Get.dialog<SpaceFileProvider>(
      const ProviderPickerDialog(),
    );
    if (result != null) {
      controller.addFileProvider(result);
    }
  }

  Future<void> _confirmDelete(
      SpacesDetailController controller) async {
    final confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('Delete Space'),
        content: Text(
            'Delete "${controller.titleController.text}"? This cannot be undone.'),
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
    if (confirmed == true) {
      final spacesService = Get.find<SpacesService>();
      try {
        await spacesService.deleteSpace(widget.spaceId!);
        Get.back();
      } catch (e) {
        Get.snackbar('Error', 'Failed to delete space: $e');
      }
    }
  }
}
