
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:seraph_app/src/media_player/audio_player_controller.dart';

class AudioPlayerView extends StatelessWidget {

  static const String routeName = '/player';
  
  const AudioPlayerView({super.key});

  format(Duration d) => d.toString().split('.').first.padLeft(8, "0");

  @override
  Widget build(BuildContext context) {
    final AudioPlayerController controller = Get.find();

    return Dismissible(
      key: GlobalKey(),
      direction: DismissDirection.down,
      onDismissed: (dir) => Get.back(),
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
          leading: IconButton(
            icon: const Icon(Icons.expand_more),
            onPressed: () {
              Get.back();
            },
          ),
          actions: [
            IconButton(icon: const Icon(Icons.close),
            onPressed: () {
              controller.closePlayer();
              Get.back();
            })
          ],
        ),
        body: Container(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 4,
              children: [
                Obx(() => Text(controller.currentMediaItem.value?.title ?? 'No Media')),
                Obx(() {
                  final value = controller.position.value.inSeconds.toDouble();
                  var max = controller.currentMediaItem.value?.duration?.inSeconds.toDouble() ?? 0;
                  if (max <= value) {
                    max = value + 1;
                  }
                  return Slider(
                    year2023: false,
                    max: max,
                    value: value,
                    onChanged: (value) {
                      controller.seek(Duration(seconds: value.toInt()));
                    }
                  );
                }),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Obx(() => Text("${format(controller.position.value)} / ${format(controller.currentMediaItem.value?.duration ?? const Duration())}", style: GoogleFonts.robotoMono()))
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  spacing: 16,
                  children: [
                    Obx(() => IconButton(
                      icon: const Icon(Icons.skip_previous),
                      iconSize: 30,
                      onPressed: controller.currentIndex.value <= 0 ? null : controller.previous,
                    )),
                    Obx(() => IconButton.filledTonal(
                      icon: _playButtonIcon(controller.playing.value, controller.buffering.value),
                      iconSize: 50,
                      onPressed: controller.playing.value ? controller.pause : controller.play,
                    )),
                    Obx(() => IconButton(
                      icon: const Icon(Icons.skip_next),
                      iconSize: 30,
                      onPressed: controller.currentIndex.value >= controller.playlist.length - 1 ? null : controller.next,
                    )),
                  ]
                )
              ]
            ),
          ),
        ),
      ),
    );
  }

  Widget _playButtonIcon(bool playing, bool buffering) {
    if (buffering) {
      return const SizedBox(
        width: 50,
        height: 50,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
        ),
      );
    }
    return playing ? const Icon(Icons.pause) : const Icon(Icons.play_arrow);
  }
}