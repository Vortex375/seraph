import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:media_kit/media_kit.dart';

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {

  Player? _player;
  Future<Player>? _playerSetupFuture;

  int _queuePosition = -1;

  Timer? _tokenRefreshTimer;
  Timer? _stopTimer;

  bool _updatingHeaders = false;

  Future<Player> _getPlayer() async {
    if (_playerSetupFuture != null) {
      return _playerSetupFuture!;
    }

    _playerSetupFuture = _doGetPlayer();
    final ret = await _playerSetupFuture!;
    _playerSetupFuture = null;

    return ret;
  }

  Future<Player> _doGetPlayer() async {
    if (_stopTimer != null) {
      _stopTimer!.cancel();
      _stopTimer = null;
    }

    if (_player != null) {
      return _player!;
    }

    _player = Player();
    _player!.stream.playlist.listen((pl) {
      if (queue.value.isEmpty) {
        mediaItem.add(null);
      } else {
        mediaItem.add(queue.value[pl.index]);
      }
      playbackState.add(playbackState.value.copyWith(
        queueIndex: pl.index
      ));
      _queuePosition = pl.index;
    });
    _player!.stream.duration.listen((duration) {
      if (_queuePosition > 0 && _queuePosition < queue.value.length) {
        queue.value[_queuePosition] = queue.value[_queuePosition].copyWith(
          duration: duration
        );
        mediaItem.add(queue.value[_queuePosition]);
      }
      mediaItem.add(mediaItem.value?.copyWith(duration: duration));
    });
    _player!.stream.position.listen((position) {
      playbackState.add(playbackState.value.copyWith(
        updatePosition: position
      ));
    });
    _player!.stream.buffering.listen((buffering) {
      playbackState.add(playbackState.value.copyWith(
        processingState: buffering ? AudioProcessingState.buffering : AudioProcessingState.ready
      ));
    });
    _player!.stream.error.listen((err) {
      print("playback error: $err");
      playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.error,
        errorMessage: err
      ));
      stop();
    });

    await _player!.open(_getPlaylist(), play: false);
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
    final player = _player;
    _player = null;
    await player?.dispose();

    await _setPlayingState(false);
    mediaItem.add(null);
    playbackState.add(PlaybackState(processingState: AudioProcessingState.idle));
  }

  Future<void> _setPlayingState(bool playing) async {
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
      updatePosition: _player?.state.position ?? const Duration(seconds: 0),
    ));
    await playbackState.firstWhere((state) => state.playing == playing);

    if (playing) {
      _tokenRefreshTimer = Timer(const Duration(seconds: 30), _refreshToken);
    } else {
      _tokenRefreshTimer?.cancel();
      _tokenRefreshTimer = null;
    }
  }

  @override
  Future<void> play() async {
    await _setPlayingState(true);
    await (await _getPlayer()).play();
  }

  @override
  Future<void> pause() async {
    if (_player == null) {
      return;
    }
    _stopTimer = Timer(const Duration(minutes: 5), stop);
    await _setPlayingState(false);
    await _player!.pause();
  }

  @override
  Future<void> stop() async {
    await _player?.stop();
    await _disposePlayer();
    await super.stop();
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
  Future<void> seek(Duration position) async {
    if (_player == null) {
      return;
    }
    await _player!.seek(position);
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
          await _player!.add(Media(queue.value[i].id, httpHeaders: extras?.map((k, v) => MapEntry(k, v.toString()))));
          await _player!.stream.playlist.first;
          if (i != queue.value.length-1) {
            await _player!.move(queue.value.length-1, i);
            await _player!.stream.playlist.first;
          }
        }
      }
      _updatingHeaders = false;
      print("updating audio player request headers complete");
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

  void _triggerTokenRefresh() {
    _tokenRefreshTimer = Timer(const Duration(seconds: 30), _refreshToken);
  }

  void _refreshToken() {
    customEvent.add('refreshToken');
    if (_player != null && (_player?.state.playing ?? false)) {
      _triggerTokenRefresh();
    } else {
      _tokenRefreshTimer = null;
    }
  }
}