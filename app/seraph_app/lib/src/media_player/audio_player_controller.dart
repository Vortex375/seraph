
import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/login/login_controller.dart';
import 'package:seraph_app/src/media_player/audio_handler.dart';
import 'package:path/path.dart' as p;

class AudioPlayerController extends GetxController {

  final RxList<String> playlist = RxList([]);
  final RxInt currentIndex = RxInt(-1);
  final Rx<MediaItem?> currentMediaItem = Rx(null);
  final RxBool open = false.obs;
  final RxBool playing = false.obs;
  final RxBool buffering = false.obs;
  final Rx<Duration> position = Rx(const Duration());

  late List<StreamSubscription> subscriptions;

  @override
  void onInit() {
    super.onInit();

    final MyAudioHandler audioHandler = Get.find();
    final LoginController loginController = Get.find();
    final FileService fileService = Get.find();
    subscriptions = [];

    subscriptions.add(audioHandler.queue.listen((queue) {
      playlist(queue.map((e) => e.id).toList());
    }));

    subscriptions.add(audioHandler.playbackState.listen((state) {
      playing(state.playing);
      currentIndex(state.queueIndex);
      open(state.processingState != AudioProcessingState.idle);
      position(state.position);
      buffering(state.processingState == AudioProcessingState.buffering);

      if (state.processingState == AudioProcessingState.error) {
        _showError(state.errorMessage ?? 'Unkown error');
      }
    }));

    subscriptions.add(audioHandler.mediaItem.listen((item) {
      currentMediaItem.firstRebuild = true; // required because of stupid operator== on MediaItem
      currentMediaItem(item);
    }));

    subscriptions.add(audioHandler.customEvent.listen((event) {
      if (event == 'refreshToken') {
        print("ping from audio_handler: refreshing token");
        loginController.refreshTokenIfNeeded();
      }
    }));

    subscriptions.add(loginController.currentUser.listen((user) async {
      if (user != null) {
        final headers = await fileService.getRequestHeaders();
        audioHandler.customAction('setHeaders', headers);
      }
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
    await audioHandler.stop();
  }

  Future<void> setPlaylist(List<String> files, int position) async {
    final FileService fileService = Get.find();
    final headers = await fileService.getRequestHeaders();

    final MyAudioHandler audioHandler = Get.find();
    await audioHandler.updateQueue(files.map((f) => MediaItem(
        id: fileService.getFileUrl(f), 
        title: p.basename(f),
        extras: headers
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