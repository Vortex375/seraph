
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/media_player/album_art.dart';
import 'package:seraph_app/src/media_player/audio_player_controller.dart';
import 'package:seraph_app/src/media_player/audio_player_view.dart';

class MediaBottomBar extends StatelessWidget {
  
  const MediaBottomBar({super.key});
  
  @override
  Widget build(BuildContext context) {
    final AudioPlayerController controller = Get.find();

    return Obx(() {
      if (!controller.open.value) {
        return const SizedBox.shrink();
      }

      int? duration = controller.currentMediaItem.value?.duration?.inMilliseconds;
      int position = controller.position.value.inMilliseconds;
      double value;
      if (duration != null) {
        value = position.toDouble() / duration.toDouble();
      } else {
        value = -1;
      }

      return IntrinsicHeight(
        child: SafeArea(
          child: Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: InkWell(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Row(children: [
                      Obx(() => IconButton.filledTonal(
                        icon: _playButtonIcon(controller.playing.value, controller.buffering.value),
                        onPressed: controller.playing.value ? controller.pause : controller.play
                      )),
                      const SizedBox(width: 8),
                      Obx(() => AlbumArt(item: controller.currentMediaItem.value, size: 40)),
                      const SizedBox(width: 8),
                      Expanded(child: Obx(() {
                        final item = controller.currentMediaItem.value;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(item?.title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                            if (item?.artist case final String artist)
                              Text(artist,
                                  style: Theme.of(context).textTheme.bodySmall,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                          ],
                        );
                      })),
                      const SizedBox(width: 8),
                      IconButton(onPressed: controller.closePlayer, icon: const Icon(Icons.close))
                    ]),
                  ),
                  if (value >= 0.0 && value <= 1.0) LinearProgressIndicator(value: value)
                ],
              ),
              onTap: () => Get.toNamed(AudioPlayerView.routeName),
            ),
          ),
        ),
      );
    });
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