
import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/share/share_dialog.dart';
import 'package:seraph_app/src/share/share_edit_controller.dart';
import 'package:webdav_client/webdav_client.dart';

class ShareController extends GetxController{

  static const String routeName = '/share';

  final RxBool shareMode = false.obs;
  final RxBool fail = false.obs;
  final RxBool ready = false.obs;

  final Rx<String?> title = Rx(null);
  final RxBool isDir = false.obs;

  final RxMap<String, String> sharedPaths = RxMap();

  init() async {
    shareMode.value = Uri.base.fragment.startsWith(routeName);

    final SettingsController settingsController = Get.find();
    final dio = Dio(BaseOptions(baseUrl: settingsController.serverUrl.value));
    
    if (shareMode.value) {
      final String shareId;
      int index = Uri.base.fragment.indexOf('?path=');
      if (index < 0) {
        fail.value = true;
        ready.value = true;
        return;
      }
      final String path = Uri.base.fragment.substring(index + 6);
      final split = path.split('/');
      if (path.startsWith('/') && split.length > 1) {
        shareId = split[1];
      } else if (split.isNotEmpty) {
        shareId = split[0];
      } else {
        fail.value = false;
        ready.value = true;
        return;
      }

      try {
        final share = await dio.get('/public-api/shares/$shareId');
        
        final list = List.from(share.data);
        title.value = Map.from(list[0])['title'].toString();
        isDir.value = Map.from(list[0])['isDir'];

      } catch (err) {
        print("Error while loading share: $err");
        fail.value = true;
      } finally {
        ready.value = true;
      }
    }
  }

  bool isShared(String path) {
    if (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (!path.startsWith('/')) {
      path = "/$path";
    }
    return sharedPaths.containsKey(path);
  }

  String? getShareFor(String path) {
    if (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (!path.startsWith('/')) {
      path = "/$path";
    }
    return sharedPaths[path];
  }

  Future<void> loadShares() async {
    final SettingsController settingsController = Get.find();
    final dio = Dio(BaseOptions(baseUrl: settingsController.serverUrl.value));

    final shares = await dio.get('/api/shares');
    final list = List.from(shares.data);
    sharedPaths.clear();
    for (dynamic item in list) {
      final map = Map.from(item);
      String shareId = map['shareId'].toString();
      String providerId = map['providerId'].toString();
      String path = map['path'].toString();
      if (!path.startsWith('/')) {
        path = "/$path";
      }
      sharedPaths["/$providerId$path"] = shareId;
    }
    print("sharedPaths: $sharedPaths");
  }

  Future<void> createShare(File file) async {
    final controller = ShareEditController();
    await controller.newShare(file);
    Get.put(controller);
    Get.dialog(const ShareDialog()).then((_) => Get.delete<ShareEditController>());
  }

  Future<void> editShare(String shareId) async {
    final controller = ShareEditController();
    await controller.existingShare(shareId);
    Get.put(controller);
    Get.dialog(const ShareDialog()).then((_) => Get.delete<ShareEditController>());
  }
}