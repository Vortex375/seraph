import 'dart:async';
import 'dart:developer' as developer;

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:seraph_app/src/media_player/audio_tags.dart';
import 'package:seraph_app/src/media_player/authenticated_audio_source.dart';
import 'package:seraph_app/src/media_player/queue_model.dart';

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {

  static const String moveQueueItemAction = 'moveQueueItem';

  AudioPlayer? _player;
  List<StreamSubscription> _subscriptions = [];

  int _queuePosition = -1;

  final QueueModel<MediaItem> _queueModel = const QueueModel<MediaItem>();

  Timer? _stopTimer;

  QueueState<MediaItem> get _state => QueueState(queue.value, _queuePosition);

  /// Publishes the model's new order and current index to audio_service. The
  /// playing entry stays the same for append/insert/move, so its [MediaItem]
  /// is not replaced and playback is not interrupted.
  void _publish(QueueState<MediaItem> state) {
    _queuePosition = state.currentIndex;
    queue.add(state.entries);
    if (state.currentIndex >= 0 && state.currentIndex < state.entries.length) {
      final current = state.entries[state.currentIndex];
      final existing = mediaItem.value;
      // Keep the duration the player already reported for the same entry;
      // queue entries themselves carry no duration.
      _setMediaItem(existing != null && existing.id == current.id
          ? current.copyWith(duration: existing.duration)
          : current);
      playbackState.add(playbackState.value.copyWith(queueIndex: state.currentIndex));
    } else {
      mediaItem.add(null);
    }
  }

  /// Headers for loading [MediaItem.artUri] (the current bearer); set by the
  /// controller. Read on every publish: Android's notification fetches the
  /// art itself, and a token captured when the queue was built has long
  /// expired by the time a later track plays.
  Map<String, String> Function()? artHeaders;

  void _setMediaItem(MediaItem? item) {
    final headers = artHeaders;
    if (item == null || item.artUri == null || headers == null) {
      mediaItem.add(item);
      return;
    }
    // copyWith has no artHeaders (and drops them)
    mediaItem.add(MediaItem(
      id: item.id,
      title: item.title,
      album: item.album,
      artist: item.artist,
      genre: item.genre,
      duration: item.duration,
      artUri: item.artUri,
      artHeaders: headers(),
      playable: item.playable,
      displayTitle: item.displayTitle,
      displaySubtitle: item.displaySubtitle,
      displayDescription: item.displayDescription,
      rating: item.rating,
      extras: item.extras,
    ));
  }

  /// Applies [tags] to every queue entry of file URL [id] (a file may be
  /// queued twice) and, when one of them is playing, to [mediaItem] - which
  /// updates the notification and lock screen. Entries are replaced, never
  /// mutated: [MediaItem]'s equality would hide the change.
  void applyTags(String id, AudioTags tags) {
    queue.add([
      for (final entry in queue.value) entry.id == id ? tags.applyTo(entry) : entry
    ]);
    final current = mediaItem.value;
    if (current != null && current.id == id) {
      _setMediaItem(tags.applyTo(current));
    }
  }

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
          _setMediaItem(queue.value[index].copyWith(duration: player.duration));
        }
      }),
      player.durationStream.listen((duration) {
        _setMediaItem(mediaItem.value?.copyWith(duration: duration));
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
    if (queue.value.isEmpty) {
      return;
    }
    try {
      await player.setAudioSources(
        queue.value.map(audioSourceFor).toList(),
        initialIndex: _queuePosition.clamp(0, queue.value.length - 1),
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
    // The file viewer's Play button keeps its behaviour: replace the queue and
    // load it lazily on the next play().
    final next = _queueModel.replace(_state, queue, 0);
    _publish(next);
    await _player?.stop();
    await _player?.clearAudioSources();
  }

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    if (mediaItems.isEmpty) {
      return;
    }
    final next = _queueModel.append(_state, mediaItems);
    _publish(next);
    final player = _player;
    if (player != null && player.audioSource != null) {
      await player.addAudioSources(mediaItems.map(audioSourceFor).toList());
    }
  }

  @override
  Future<void> insertQueueItem(int index, MediaItem mediaItem) async {
    final at = index.clamp(0, queue.value.length);
    final entries = [...queue.value]..insert(at, mediaItem);
    var current = _queuePosition;
    if (current < 0) {
      current = 0;
    } else if (at <= current) {
      current++;
    }
    _publish(QueueState(entries, current));
    final player = _player;
    if (player != null && player.audioSource != null) {
      await player.insertAudioSource(at, audioSourceFor(mediaItem));
    }
  }

  @override
  Future<void> removeQueueItemAt(int index) async {
    if (index < 0 || index >= queue.value.length) {
      return;
    }
    final oldCurrent = _queuePosition;
    final wasPlaying = _player?.playing ?? false;
    final next = _queueModel.removeAt(_state, index);
    _publish(next);
    if (next.entries.isEmpty) {
      // Emptying the queue stops the player and dismisses the notification.
      await stop();
      return;
    }

    final player = _player;
    if (player == null || player.audioSource == null) {
      return;
    }
    await player.removeAudioSourceAt(index);
    if (index == oldCurrent) {
      // Continue with the entry that is now current.
      await player.seek(Duration.zero, index: next.currentIndex);
      if (wasPlaying) {
        unawaited(player.play());
      }
    }
  }

  /// audio_service has no standard move action, so the queue view uses
  /// [customAction] with [moveQueueItemAction].
  Future<void> moveQueueItem(int from, int to) async {
    final length = queue.value.length;
    if (from < 0 || from >= length || to < 0 || to >= length || from == to) {
      return;
    }
    _publish(_queueModel.move(_state, from, to));
    final player = _player;
    if (player != null && player.audioSource != null) {
      await player.moveAudioSource(from, to);
    }
  }

  @override
  Future<dynamic> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == moveQueueItemAction) {
      final from = extras?['from'];
      final to = extras?['to'];
      if (from is int && to is int) {
        await moveQueueItem(from, to);
      }
      return null;
    }
    return super.customAction(name, extras);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= queue.value.length) {
      return;
    }
    _queuePosition = index;
    final current = queue.value[index];
    final existing = mediaItem.value;
    _setMediaItem(existing != null && existing.id == current.id
        ? current.copyWith(duration: existing.duration)
        : current);
    playbackState.add(playbackState.value.copyWith(queueIndex: index));
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
