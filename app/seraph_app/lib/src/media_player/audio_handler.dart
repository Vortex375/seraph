import 'dart:async';
import 'dart:developer' as developer;

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:seraph_app/src/media_player/authenticated_audio_source.dart';

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {

  AudioPlayer? _player;
  List<StreamSubscription> _subscriptions = [];

  int _queuePosition = 0;

  Timer? _stopTimer;

  AudioPlayer _getPlayer() {
    _stopTimer?.cancel();
    _stopTimer = null;
    return _player ??= _createPlayer();
  }

  AudioPlayer _createPlayer() {
    final player = AudioPlayer();
    _subscriptions = [
      player.playbackEventStream.listen((_) => _broadcastState(player)),
      player.playingStream.listen((_) => _broadcastState(player)),
      player.currentIndexStream.listen((index) {
        if (index != null && index < queue.value.length) {
          _queuePosition = index;
          mediaItem.add(queue.value[index].copyWith(duration: player.duration));
        }
      }),
      player.durationStream.listen((duration) {
        mediaItem.add(mediaItem.value?.copyWith(duration: duration));
      }),
      player.errorStream.listen((err) {
        developer.log("playback error: $err", name: 'seraph.media_player', error: err);
        playbackState.add(playbackState.value.copyWith(
          processingState: AudioProcessingState.error,
          errorMessage: err.message ?? 'Playback failed',
        ));
      }),
    ];
    return player;
  }

  void _broadcastState(AudioPlayer player) {
    final playing = player.playing;
    playbackState.add(playbackState.value.copyWith(
      controls: [
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToPrevious,
        MediaControl.skipToNext,
      ],
      androidCompactActionIndices: const [0, 1, 2],
      processingState: const {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[player.processingState]!,
      playing: playing,
      updatePosition: player.position,
      bufferedPosition: player.bufferedPosition,
      queueIndex: player.currentIndex,
    ));
  }

  Future<void> _disposePlayer() async {
    _stopTimer?.cancel();
    _stopTimer = null;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions = [];
    final player = _player;
    _player = null;
    await player?.dispose();

    mediaItem.add(null);
    playbackState.add(PlaybackState(processingState: AudioProcessingState.idle));
  }

  Future<void> _load(AudioPlayer player) async {
    try {
      await player.setAudioSources(
        queue.value.map(audioSourceFor).toList(),
        initialIndex: _queuePosition,
      );
    } on PlayerException catch (err) {
      // already reported through errorStream
      developer.log("loading queue failed: $err", name: 'seraph.media_player', error: err);
    } on PlayerInterruptedException {
      // superseded by a newer load
    }
  }

  @override
  Future<void> play() async {
    final player = _getPlayer();
    if (player.audioSource == null) {
      await _load(player);
    }
    // just_audio's play() completes only when playback pauses or stops
    unawaited(player.play());
  }

  @override
  Future<void> pause() async {
    final player = _player;
    if (player == null) {
      return;
    }
    _stopTimer = Timer(const Duration(minutes: 5), stop);
    await player.pause();
  }

  @override
  Future<void> stop() async {
    await _player?.stop();
    await _disposePlayer();
    await super.stop();
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    await super.updateQueue(queue);
    _queuePosition = 0;
    // the next play() loads the new queue at the then-current position
    await _player?.stop();
    await _player?.clearAudioSources();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    _queuePosition = index;
    final player = _player;
    if (player == null || player.audioSource == null) {
      return;
    }
    await player.seek(Duration.zero, index: index);
  }

  @override
  Future<void> skipToNext() async {
    await _player?.seekToNext();
  }

  @override
  Future<void> skipToPrevious() async {
    await _player?.seekToPrevious();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player?.seek(position);
  }
}
