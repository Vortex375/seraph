
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/media_player/audio_player_controller.dart';

class MediaBottomBar extends StatelessWidget {
  
  const MediaBottomBar({super.key});
  
  @override
  Widget build(BuildContext context) {
    final AudioPlayerController controller = Get.find();


    return Obx(() => !controller.open.value ? const SizedBox.shrink() : 
      SafeArea(
        child: Container(
          padding: const EdgeInsets.all(8.0),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Row(children: [
            Obx(() => controller.playing.value 
              ? IconButton.filledTonal(onPressed: controller.pause, icon: const Icon(Icons.pause))
              : IconButton.filledTonal(onPressed: controller.play, icon: const Icon(Icons.play_arrow))),
            const SizedBox(width: 8),
            Expanded(child: Obx(() => Text(controller.currentMediaItem.value?.title ?? ''))),
            const SizedBox(width: 8),
            IconButton(onPressed: controller.closePlayer, icon: const Icon(Icons.close))
          ]),
        ),
      )
    );
  }

}