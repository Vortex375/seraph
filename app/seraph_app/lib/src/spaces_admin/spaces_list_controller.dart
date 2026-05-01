import 'package:get/get.dart';
import 'package:seraph_app/src/spaces_admin/spaces_models.dart';
import 'package:seraph_app/src/spaces_admin/spaces_service.dart';

class SpacesListController extends GetxController {
  SpacesListController(this.spacesService);

  final SpacesService spacesService;

  final RxList<Space> spaces = RxList<Space>([]);
  final RxBool isLoading = false.obs;

  @override
  void onInit() {
    super.onInit();
    loadSpaces();
  }

  Future<void> loadSpaces() async {
    isLoading.value = true;
    try {
      spaces.assignAll(await spacesService.listSpaces());
    } catch (e) {
      Get.snackbar('Error', 'Failed to load spaces: $e');
    } finally {
      isLoading.value = false;
    }
  }

  Future<void> deleteSpace(String spaceId) async {
    try {
      await spacesService.deleteSpace(spaceId);
      spaces.removeWhere((s) => s.id == spaceId);
    } catch (e) {
      Get.snackbar('Error', 'Failed to delete space: $e');
    }
  }
}
