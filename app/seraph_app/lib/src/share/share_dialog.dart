
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/share/share_edit_controller.dart';

class ShareDialog extends StatelessWidget {

  const ShareDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final ShareEditController controller = Get.find();

    return Obx(() => AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.share),
          const SizedBox(width: 8),
          controller.isNew.value ? const Text('Share Item') : const Text('Edit Share')
        ]),
      content: Container(
        constraints: const BoxConstraints(minWidth: 600),
        child: Column(
          spacing: 8,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: controller.shareId,
              readOnly: !controller.isNew.value,
              decoration: const InputDecoration(
                labelText: 'ShareId',
                helperText: 'This will be part of the share URL. Make it hard to guess if you want the share to be private.'
              ),
              
            ),
            TextField(
              controller: controller.title,
              decoration: const InputDecoration(
                labelText: 'Title',
                helperText: '(optional) Add a title that will be shown when users open the share.'
              ),
            ),
            TextField(
              controller: controller.description,
              decoration: const InputDecoration(
                labelText: 'Description',
                helperText: '(optional) Add a description that will be shown when users open the share.'
              ),
            ),
            if (controller.isDir.value) Obx(() => CheckboxListTile(
              title: const Text('Include Subfolders'),
              value: controller.recursive.value,
              onChanged: (value) {
                controller.recursive.value = value ?? false;
              },
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            )),
            Obx(() => CheckboxListTile(
              title: const Text('Allow Editing'),
              value: ! controller.readOnly.value,
              onChanged: (value) {
                controller.readOnly.value = ! (value ?? false);
              },
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
            )),
          ],
        ),
      ),
      actions: [
        if (!controller.isNew.value) TextButton(
          onPressed: controller.unshare,
          child: Text('Unshare', style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ),
        TextButton(
          onPressed: () => Get.back(), // Close dialog
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: controller.submit,
          child: const Text('Submit'),
        ),
      ],
    ));
  }

}
