
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/media_player/audio_player_controller.dart';
import 'package:seraph_app/src/media_player/queue_view.dart';

class AudioPlayerView extends StatefulWidget {

  static const String routeName = '/player';
  
  const AudioPlayerView({super.key});

  @override
  State<AudioPlayerView> createState() => _AudioPlayerViewState();
}

class _AudioPlayerViewState extends State<AudioPlayerView> {

  /// The thumb position while the user drags. Kept local so playback (and the
  /// position stream) is not seeked on every change; a single seek happens on
  /// release.
  Duration? _dragPosition;

  String format(Duration d) => d.toString().split('.').first.padLeft(8, "0");

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
            IconButton(
              icon: const Icon(Icons.queue_music),
              tooltip: 'Queue',
              onPressed: () {
                showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  showDragHandle: true,
                  builder: (context) => const FractionallySizedBox(
                    heightFactor: 0.7,
                    child: QueueView(),
                  ),
                );
              },
            ),
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
                  final duration = controller.currentMediaItem.value?.duration;
                  final shown = _dragPosition ?? controller.position.value;
                  final max = duration?.inMilliseconds.toDouble() ?? 0;
                  final hasDuration = max > 0;
                  final value = hasDuration
                      ? shown.inMilliseconds.clamp(0, max.toInt()).toDouble()
                      : 0.0;
                  final buffered = hasDuration
                      ? controller.bufferedPosition.value.inMilliseconds
                          .clamp(value.toInt(), max.toInt())
                          .toDouble()
                      : 0.0;
                  return Slider(
                    max: hasDuration ? max : 1,
                    value: value,
                    secondaryTrackValue: hasDuration ? buffered : null,
                    onChangeStart: hasDuration
                        ? (value) => setState(
                            () => _dragPosition = Duration(milliseconds: value.round()))
                        : null,
                    onChanged: hasDuration
                        ? (value) => setState(
                            () => _dragPosition = Duration(milliseconds: value.round()))
                        : null,
                    onChangeEnd: hasDuration
                        ? (value) {
                            setState(() => _dragPosition = null);
                            controller.seek(Duration(milliseconds: value.round()));
                          }
                        : null,
                  );
                }),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Obx(() => Text(
                      "${format(_dragPosition ?? controller.position.value)} / ${format(controller.currentMediaItem.value?.duration ?? const Duration())}",
                      style: const TextStyle(fontFamily: 'monospace'),
                    ))
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
