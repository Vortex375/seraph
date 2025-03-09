
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';

class MediaPlayerController extends GetxController {

  final RxList<String> playlist = RxList([]);
  final RxInt currentIndex = RxInt(-1);
  final RxBool open = false.obs;
  final RxBool playing = false.obs;

  Player? _player;

  Future<void> closePlayer() async {
    if (_player != null) {
      await _player!.stop();
      await _player!.dispose();
      _player = null;
    }

    playlist([]);
    currentIndex(-1);
    playing(false);
    open(false);
  }

  Future<void> setPlaylist(List<String> files, int position) async {
    final FileService fileService = Get.find();
    final headers = await fileService.getRequestHeaders();

    final pl = Playlist(
      files.map((f) => Media(
        fileService.getFileUrl(f),
        httpHeaders: headers
      )).toList(), 
      index: position
    );

    playlist(files);
    currentIndex(position);
    await _getPlayer().open(pl);
  }

  Future<void> playOrPause() async {
    if (_player == null) {
      return;
    }
    await _player!.playOrPause();
  }

  Future<void> play() async {
    if (_player == null) {
      return;
    }
    await _player!.play();
  }

  Future<void> pause() async {
    if (_player == null) {
      return;
    }
    await _player!.pause();
  }

  @override
  void onClose() {
    super.onClose();
    if (_player != null) {
      _player!.dispose();
    }
  }

  Player _getPlayer() {
    if (_player != null) {
      return _player!;
    }

    _player = Player();
    _player!.stream.playing.listen(playing.call);
    _player!.stream.error.listen(_showError);

    open(true);

    return _player!;
  }

  void _showError(String error) {
    Get.snackbar('Playback error', error,
        backgroundColor: Colors.amber[800],
        isDismissible: true
      );
  }
}