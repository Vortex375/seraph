
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';
import 'package:seraph_app/src/share/share_controller.dart';
import 'package:webdav_client/webdav_client.dart';

class ShareEditController extends GetxController {
  final shareId = TextEditingController();
  final title = TextEditingController();
  final description = TextEditingController();
  final recursive = RxBool(false);
  final readOnly = RxBool(true);

  final isNew = RxBool(true);
  final path = RxString('');
  final isDir = RxBool(false);

  Future<void> newShare(File file) async {
    isNew.value = true;
    isDir.value = file.isDir ?? false;
    path.value = file.path ?? "";
    shareId.text = generateRandomShareId(24);
  }
  
  Future<void> existingShare(String existingShareId) async {
    shareId.text = existingShareId;
    isNew.value = false;

    final SettingsController settingsController = Get.find();
    final dio = Dio(BaseOptions(baseUrl: settingsController.serverUrl.value));
    final shares = await dio.get('/api/shares/$existingShareId');
    final list = List.from(shares.data);
    for (dynamic item in list) { // there should be 1 item only
      final map = Map.from(item);
      title.text = map['title'];
      description.text = map['description'];
      recursive.value = map['recursive'];
      readOnly.value = map['readOnly'];
      isDir.value = map['isDir'];
      String p = map['path'];
      if (!p.startsWith("/")) {
        p = "/$p";
      }
      path.value = "${map['providerId']}$p";
    }
  }

  Future<void> submit() async {
    final ShareController shareController = Get.find();
    final SettingsController settingsController = Get.find();
    final dio = Dio(BaseOptions(baseUrl: settingsController.serverUrl.value));
    
    String p = path.value;
    if (p.startsWith("/")) {
      p = p.substring(1);
    }
    int index = p.indexOf("/");
    if (index < 0) {
      return;
    }
    final providerId = p.substring(0, index);
    p = p.substring(index);
    
    final share = {
      'shareId': shareId.text,
      'title': title.text,
      'description': description.text,
      'providerId': providerId,
      'path': p,
      'recursive': recursive.value,
      'readOnly': readOnly.value,
      'isDir': isDir.value
    };

    try {
      if (isNew.value) {
        await dio.post('/api/shares',
          data: share,
          options: Options(
            headers: {
              'Content-Type': 'application/json',
            },
          ),
        );
      } else {
        await dio.put('/api/shares/${shareId.text}',
          data: share,
          options: Options(
            headers: {
              'Content-Type': 'application/json',
            },
          ),
        );
      }
      
      Get.back();
      Get.snackbar('Success', 'Share ${isNew.value ? 'created' : 'updated'}');
      shareController.loadShares();
    } catch (e) {
      Get.snackbar('${isNew.value ? 'Create' : 'Edit'} share failed', e.toString(),
        backgroundColor: Colors.amber[800],
        isDismissible: true
      );
    }
  }

  Future<void> unshare() async {
    final ShareController shareController = Get.find();
    final SettingsController settingsController = Get.find();
    final dio = Dio(BaseOptions(baseUrl: settingsController.serverUrl.value));

    try {
      await dio.delete("/api/shares/${shareId.text}");

      Get.back();
      Get.snackbar('Success', 'Share deleted');
      shareController.loadShares();
    } catch (e) {
      Get.snackbar('Delete share failed', e.toString(),
        backgroundColor: Colors.amber[800],
        isDismissible: true
      );
    }
  }

  String generateRandomShareId(int length) {
  const characters = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final random = Random.secure();
  return String.fromCharCodes(Iterable.generate(
    length,
    (_) => characters.codeUnitAt(random.nextInt(characters.length)),
  ));
}
}