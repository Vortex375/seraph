
import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';

class ShareController extends GetxController{

  static const String routeName = '/share';

  final RxBool shareMode = false.obs;
  final RxBool fail = false.obs;
  final RxBool ready = false.obs;

  final Rx<String?> title = Rx(null);

  init() async {
    shareMode.value = Uri.base.fragment.startsWith(routeName);

    if (shareMode.value) {
      final SettingsController settingsController = Get.find();
      final dio = Dio(BaseOptions(baseUrl: settingsController.serverUrl.value));

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

      } catch (err) {
        print("Error while loading share: $err");
        fail.value = true;
      } finally {
        ready.value = true;
      }
    }
  }
}