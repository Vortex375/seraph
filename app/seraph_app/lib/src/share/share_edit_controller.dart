
import 'package:flutter/material.dart';
import 'package:get/get.dart';

class ShareEditController extends GetxController {
  final shareId = TextEditingController();
  final title = TextEditingController();
  final description = TextEditingController();
  final recursive = RxBool(false);
  final readOnly = RxBool(false);

  final isNew = RxBool(true);
  final path = RxString('');
  final isDir = RxBool(false);
  

  void submit() {
    Get.back();
    Get.snackbar('Success', 'Submitted');
  }
}