import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/spaces_admin/spaces_models.dart';
import 'package:seraph_app/src/spaces_admin/spaces_service.dart';

class SpacesDetailController extends GetxController {
  SpacesDetailController(this.spacesService, {this.spaceId});

  final SpacesService spacesService;
  final String? spaceId;

  final titleController = TextEditingController();
  final descriptionController = TextEditingController();
  final userInputController = TextEditingController();

  final List<TextEditingController> providerNameControllers = [];
  final List<TextEditingController> providerPathControllers = [];

  final RxList<String> users = RxList<String>([]);
  final RxList<SpaceFileProvider> fileProviders = RxList<SpaceFileProvider>([]);
  final RxBool isLoading = false.obs;
  final RxBool isSaving = false.obs;
  final RxnString error = RxnString();

  bool get isEditing => spaceId != null;

  @override
  void onInit() {
    super.onInit();
    if (isEditing) {
      loadSpace();
    }
  }

  @override
  void onClose() {
    titleController.dispose();
    descriptionController.dispose();
    userInputController.dispose();
    for (final c in providerNameControllers) {
      c.dispose();
    }
    for (final c in providerPathControllers) {
      c.dispose();
    }
    super.onClose();
  }

  Future<void> loadSpace() async {
    isLoading.value = true;
    error.value = null;
    try {
      final space = await spacesService.getSpace(spaceId!);
      titleController.text = space.title;
      descriptionController.text = space.description;
      users.assignAll(space.users);
      fileProviders.assignAll(space.fileProviders);
      providerNameControllers.clear();
      providerPathControllers.clear();
      for (final fp in space.fileProviders) {
        providerNameControllers.add(TextEditingController(text: fp.spaceProviderId));
        providerPathControllers.add(TextEditingController(text: fp.path));
      }
    } catch (e) {
      error.value = 'Failed to load space: $e';
    } finally {
      isLoading.value = false;
    }
  }

  void addUser() {
    final text = userInputController.text.trim();
    if (text.isNotEmpty && !users.contains(text)) {
      users.add(text);
      userInputController.clear();
    }
  }

  void removeUser(String user) {
    users.remove(user);
  }

  void addFileProvider(SpaceFileProvider fp) {
    fileProviders.add(fp);
    providerNameControllers.add(TextEditingController(text: fp.spaceProviderId));
    providerPathControllers.add(TextEditingController(text: fp.path));
  }

  void updateFileProvider(int index, SpaceFileProvider fp) {
    fileProviders[index] = fp;
  }

  void removeFileProvider(int index) {
    if (index < providerNameControllers.length) {
      providerNameControllers[index].dispose();
      providerNameControllers.removeAt(index);
    }
    if (index < providerPathControllers.length) {
      providerPathControllers[index].dispose();
      providerPathControllers.removeAt(index);
    }
    fileProviders.removeAt(index);
  }

  Future<bool> save() async {
    if (titleController.text.trim().isEmpty) {
      Get.snackbar('Validation', 'Title is required');
      return false;
    }

    isSaving.value = true;
    try {
      final space = Space(
        id: spaceId,
        title: titleController.text.trim(),
        description: descriptionController.text.trim(),
        users: users.toList(),
        fileProviders: fileProviders.toList(),
      );

      if (isEditing) {
        await spacesService.updateSpace(spaceId!, space);
      } else {
        await spacesService.createSpace(space);
      }
      return true;
    } catch (e) {
      Get.snackbar('Error', 'Failed to save space: $e');
      return false;
    } finally {
      isSaving.value = false;
    }
  }
}
