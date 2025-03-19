import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:media_kit/media_kit.dart';

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {

  Player? _player;
  int _queuePosition = -1;

  Timer? _stopTimer;

  bool _updatingHeaders = false;

  Future<Player> _getPlayer() async {
    if (_stopTimer != null) {
      _stopTimer!.cancel();
      _stopTimer = null;
    }

    if (_player != null) {
      return _player!;
    }

    _player = Player();
    _player!.stream.playlist.listen((pl) {
      print("playlist is now");
      for (final m in pl.medias) {
        print(m.uri);
      }
      if (queue.value.isEmpty) {
        mediaItem.add(null);
      } else {
        mediaItem.add(queue.value[pl.index]);
      }
      playbackState.add(playbackState.value.copyWith(
        queueIndex: pl.index
      ));
    });
    _player!.stream.duration.listen((duration) {
      mediaItem.add(mediaItem.value?.copyWith(duration: duration));
    });
    _player!.stream.playing.listen((playing) {
      playbackState.add(playbackState.value.copyWith(
        processingState:AudioProcessingState.ready,
        playing: playing,
        controls: playing ? [
          MediaControl.pause,
          MediaControl.skipToPrevious,
          MediaControl.skipToNext
        ] : [
          MediaControl.play,
          MediaControl.skipToPrevious,
          MediaControl.skipToNext
        ],
        androidCompactActionIndices: playing ? [0, 1, 2] : [0, 1, 2],
        updatePosition: _player!.state.position,
      ));
    });
    _player!.stream.error.listen((err) {
      playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.error,
        errorMessage: err
      ));
    });

    await _player!.open(_getPlaylist());
    if (_queuePosition > 0 && _queuePosition < queue.value.length) {
      await _player!.jump(_queuePosition);
    }

    return _player!;
  }

  Future<void> _disposePlayer() async {
    if (_stopTimer != null) {
      _stopTimer!.cancel();
      _stopTimer = null;
    }
    await _player!.dispose();
    _player = null;

    mediaItem.add(null);
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      processingState: AudioProcessingState.idle
    ));
  }

  @override
  Future<void> play() async {
    await (await _getPlayer()).play();
  }

  @override
  Future<void> pause() async {
    if (_player == null) {
      return;
    }
    _stopTimer = Timer(const Duration(minutes: 5), stop);
    await _player!.pause();
  }

  @override
  Future<void> stop() async {
    if (_player == null) {
      return;
    }
    await _player!.stop();
    await _disposePlayer();
  }

  @override
  Future<void> updateQueue(List<MediaItem> newQueue) async {
    await super.updateQueue(newQueue);

    await _getPlayer();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    _queuePosition = index;
    if (_player == null) {
      return;
    }
    await (await _getPlayer()).jump(index);
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'setHeaders') {
      if (_updatingHeaders) {
        return;
      }
      _updatingHeaders = true;

      print("updating audio player request headers");
      queue.add(queue.value.map((media) => media.copyWith(extras: extras)).toList());
      if (_player != null) {
        for (var i = 0; i < queue.value.length; i++) {
          if (i == _player!.state.playlist.index) {
            /* do not update the currently playing item */
            continue;
          }

          await _player!.remove(i);
          await _player!.stream.playlist.first;
          await _player!.add(Media(queue.value[i].id, extras: extras?.map((k, v) => MapEntry(k, v.toString()))));
          await _player!.stream.playlist.first;
          if (i != queue.value.length-1) {
            await _player!.move(queue.value.length-1, i);
            await _player!.stream.playlist.first;
          }
        }
      }
      _updatingHeaders = false;
    }
  }

  Playlist _getPlaylist() {
    return Playlist(
      queue.value.map((i) => Media(
        i.id,
        httpHeaders: i.extras?.map((k, v) => MapEntry(k, v.toString()))
      )).toList(),
    );
  }
}