
import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/media_player/audio_handler.dart';
import 'package:path/path.dart' as p;

class AudioPlayerController extends GetxController {

  final RxList<String> playlist = RxList([]);
  final RxInt currentIndex = RxInt(-1);
  final RxBool open = false.obs;
  final RxBool playing = false.obs;

  late List<StreamSubscription> subscriptions;

  @override
  void onInit() {
    super.onInit();

    final MyAudioHandler audioHandler = Get.find();
    subscriptions = [];

    subscriptions.add(audioHandler.queue.listen((queue) {
      playlist(queue.map((e) => e.id).toList());
    }));

    subscriptions.add(audioHandler.playbackState.listen((state) {
      playing(state.playing);
      currentIndex(state.queueIndex);

      if (state.processingState == AudioProcessingState.error) {
        _showError(state.errorMessage ?? 'Unkown error');
      }
    }));

    subscriptions.add(audioHandler.mediaItem.listen((mediaItem) {
      print("Current Media Item: $mediaItem");
    }));
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
    audioHandler.stop();
    open(false);
  }

  Future<void> setPlaylist(List<String> files, int position) async {
    final FileService fileService = Get.find();
    final headers = await fileService.getRequestHeaders();

    final MyAudioHandler audioHandler = Get.find();
    audioHandler.updateQueue(files.map((f) => MediaItem(
        id: fileService.getFileUrl(f), 
        title: p.basename(f),
        extras: headers
      )
    ).toList());

    audioHandler.skipToQueueItem(position);
    open(true);
  }

  Future<void> play() async {
    if (!open.value) {
      return;
    }
    final MyAudioHandler audioHandler = Get.find();
    audioHandler.play();
  }

  Future<void> pause() async {
    if (!open.value) {
      return;
    }
    final MyAudioHandler audioHandler = Get.find();
    audioHandler.pause();
  }

  void _showError(String error) {
    Get.snackbar('Playback error', error,
        backgroundColor: Colors.amber[800],
        isDismissible: true
      );
  }
}