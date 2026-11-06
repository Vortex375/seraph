
import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/media_player/audio_handler.dart';
import 'package:path/path.dart' as p;

class AudioPlayerController extends GetxController {

  final RxList<String> playlist = RxList([]);
  final RxList<MediaItem> queueItems = RxList([]);
  final RxInt currentIndex = RxInt(-1);
  final Rx<MediaItem?> currentMediaItem = Rx(null);
  final RxBool open = false.obs;
  final RxBool playing = false.obs;
  final RxBool buffering = false.obs;
  final Rx<Duration> position = Rx(const Duration());
  final Rx<Duration> bufferedPosition = Rx(const Duration());

  late List<StreamSubscription> subscriptions;

  @override
  void onInit() {
    super.onInit();

    final MyAudioHandler audioHandler = Get.find();
    subscriptions = [];

    subscriptions.add(audioHandler.queue.listen((queue) {
      playlist(queue.map((e) => e.id).toList());
      queueItems(queue);
    }));

    subscriptions.add(audioHandler.playbackState.listen((state) {
      playing(state.playing);
      currentIndex(state.queueIndex);
      open(state.processingState != AudioProcessingState.idle);
      position(state.position);
      bufferedPosition(state.bufferedPosition);
      buffering(state.processingState == AudioProcessingState.buffering);

      if (state.processingState == AudioProcessingState.error) {
        _showError(state.errorMessage ?? 'Unkown error');
      }
    }));

    subscriptions.add(audioHandler.mediaItem.listen((item) {
      currentMediaItem.firstRebuild = true; // required because of stupid operator== on MediaItem
      currentMediaItem(item);
    }));

    // the handler only publishes position on playback events; tick the
    // (second-resolution) UI from audio_service's extrapolation, in Dart only
    subscriptions.add(AudioService.createPositionStream(
      steps: 1,
      minPeriod: const Duration(seconds: 1),
      maxPeriod: const Duration(seconds: 1),
    ).listen((p) => position(p)));
  }

  @override
  void onClose() {
    super.onClose();
    for (var sub in subscriptions) {
      sub.cancel();
    }
  }

  Future<void> closePlayer() async {
    final MyAudioHandler audioHandler = Get.find();
    await audioHandler.stop();
  }

  Future<void> setPlaylist(List<String> files, int position) async {
    final FileService fileService = Get.find();

    final MyAudioHandler audioHandler = Get.find();
    await audioHandler.updateQueue(files.map((f) => MediaItem(
        id: fileService.getFileUrl(f), 
        title: p.basename(f),
      )
    ).toList());

    await audioHandler.skipToQueueItem(position);
  }

  Future<void> play() async {
    final MyAudioHandler audioHandler = Get.find();
    await audioHandler.play();
  }

  Future<void> pause() async {
    final MyAudioHandler audioHandler = Get.find();
    await audioHandler.pause();
  }

  Future<void> seek(Duration position) async {
    final MyAudioHandler audioHandler = Get.find();
    await audioHandler.seek(position);
  }

  Future<void> skipTo(int index) async {
    final MyAudioHandler audioHandler = Get.find();
    await audioHandler.skipToQueueItem(index);
  }

  Future<void> move(int from, int to) async {
    final MyAudioHandler audioHandler = Get.find();
    await audioHandler.customAction(
        MyAudioHandler.moveQueueItemAction, {'from': from, 'to': to});
  }

  Future<void> removeAt(int index) async {
    final MyAudioHandler audioHandler = Get.find();
    await audioHandler.removeQueueItemAt(index);
  }

  /// Adds [files] after the playing track (play next) or at the end. When
  /// nothing is playing, playback starts at the first added track.
  Future<void> enqueue(List<String> files, {required bool playNext}) async {
    if (files.isEmpty) {
      return;
    }
    final FileService fileService = Get.find();
    final items = files
        .map((f) => MediaItem(id: fileService.getFileUrl(f), title: p.basename(f)))
        .toList();
    final MyAudioHandler audioHandler = Get.find();

    final nothingPlaying = !open.value || currentIndex.value < 0;
    final firstIndex = playNext
        ? (nothingPlaying ? 0 : currentIndex.value + 1)
        : queueItems.length;

    if (playNext) {
      var index = firstIndex;
      for (final item in items) {
        await audioHandler.insertQueueItem(index++, item);
      }
    } else {
      await audioHandler.addQueueItems(items);
    }

    if (nothingPlaying) {
      await audioHandler.skipToQueueItem(firstIndex);
      await audioHandler.play();
    }
  }

  Future<void> next() async {
    final MyAudioHandler audioHandler = Get.find();
    await audioHandler.skipToNext();
  }

  Future<void> previous() async {
    final MyAudioHandler audioHandler = Get.find();
    await audioHandler.skipToPrevious();
  }

  void _showError(String error) {
    Get.snackbar('Playback error', error,
        backgroundColor: Colors.amber[800],
        isDismissible: true
      );
  }
}