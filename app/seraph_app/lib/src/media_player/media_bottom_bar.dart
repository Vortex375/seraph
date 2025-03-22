
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/media_player/audio_player_controller.dart';
import 'package:seraph_app/src/media_player/audio_player_view.dart';

class MediaBottomBar extends StatelessWidget {
  
  const MediaBottomBar({super.key});
  
  @override
  Widget build(BuildContext context) {
    final AudioPlayerController controller = Get.find();


    return Obx(() => !controller.open.value ? const SizedBox.shrink() : 
      SafeArea(
        child: InkWell(
          child: Container(
            padding: const EdgeInsets.all(8.0),
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Row(children: [
              Obx(() => IconButton.filledTonal(
                icon: _playButtonIcon(controller.playing.value, controller.buffering.value),
                onPressed: controller.playing.value ? controller.pause : controller.play
              )),
              const SizedBox(width: 8),
              Expanded(child: Obx(() => Text(controller.currentMediaItem.value?.title ?? ''))),
              const SizedBox(width: 8),
              IconButton(onPressed: controller.closePlayer, icon: const Icon(Icons.close))
            ]),
          ),
          onTap: () => Get.toNamed(AudioPlayerView.routeName),
        ),
      )
    );
  }

  Widget _playButtonIcon(bool playing, bool buffering) {
    if (buffering) {
      return const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
        ),
      );
    }
    return playing ? const Icon(Icons.pause) : const Icon(Icons.play_arrow);
  }
}