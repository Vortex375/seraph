import 'dart:async';
import 'dart:developer' as developer;

import 'package:audio_service/audio_service.dart';
import 'package:get/get.dart' hide Rx;
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:rxdart/rxdart.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/media_player/audio_tags.dart';
import 'package:seraph_app/src/media_player/authenticated_audio_source.dart';
import 'package:seraph_app/src/media_player/history_label.dart';
import 'package:seraph_app/src/media_player/history_model.dart';
import 'package:seraph_app/src/media_player/history_store.dart';
import 'package:seraph_app/src/media_player/queue_model.dart';

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {

  static const String moveQueueItemAction = 'moveQueueItem';

  AudioPlayer? _player;
  List<StreamSubscription> _subscriptions = [];

  int _queuePosition = -1;

  final QueueModel<MediaItem> _queueModel = const QueueModel<MediaItem>();

  Timer? _stopTimer;

  /// Where the next [_load] starts in the current track; set by [seek] while
  /// no source is loaded (a restored entry loads lazily on play()).
  Duration _resumePosition = Duration.zero;

  final HistoryModel _historyModel = const HistoryModel();
  HistoryStore? _historyStore;
  Future<void> _historyOps = Future.value();

  /// The playlist history, seeded empty until [loadHistory] has read it.
  final BehaviorSubject<HistoryState> history =
      BehaviorSubject.seeded(const HistoryState());

  Timer? _progressTimer;

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

  /// A queue entry for file [path]: id is the streamed URL, the title the file
  /// name until tags arrive.
  MediaItem mediaItemFor(String path) {
    final FileService fileService = Get.find();
    return MediaItem(
      id: fileService.getFileUrl(path),
      title: p.basename(path),
      artUri: Uri.parse(fileService.getAlbumArtUrl(path)),
      extras: {'path': path},
    );
  }

  /// Runs [edit] on the history after the stored state is loaded, then
  /// stores and publishes the result. Edits run one after another.
  Future<void> editHistory(HistoryState Function(HistoryState) edit) {
    return _historyOps = _historyOps.then((_) async {
      var store = _historyStore;
      if (store == null) {
        store = _historyStore = await HistoryStore.open();
        history.add(store.read());
      }
      final next = edit(history.value);
      history.add(next);
      await store.write(next);
    }).catchError((Object err) {
      developer.log("saving playlist history failed: $err", name: 'seraph.media_player', error: err);
    });
  }

  /// Reads the stored history into [history]; a no-op edit.
  Future<void> loadHistory() => editHistory((state) => state);

  /// Logout: forgets the history in memory and on disk.
  Future<void> clearHistory() async {
    await editHistory((_) => const HistoryState());
    await _historyStore?.clear();
  }

  /// The queue's file paths, or null when it is empty or holds an entry that
  /// was not built from a file path.
  List<String>? _queuePaths() => _pathsOf(queue.value);

  List<String>? _pathsOf(List<MediaItem> items) {
    final paths = [for (final item in items) mediaItemPath(item)];
    if (paths.isEmpty || paths.contains(null)) {
      return null;
    }
    return paths.cast<String>();
  }

  /// Stores the queue, current index and position. An empty queue leaves the last
  /// stored snapshot alone.
  void _saveProgress() {
    if (_replacingQueue) {
      return;
    }
    final paths = _queuePaths();
    if (paths == null) {
      return;
    }
    final index = _queuePosition.clamp(0, paths.length - 1);
    final player = _player;
    // before the first load the player reports 0, not the resume point
    final position = player == null || player.audioSource == null ? _resumePosition : player.position;
    unawaited(editHistory((state) => _historyModel.updateCurrent(
        state, paths, index, position.inMilliseconds, DateTime.now().millisecondsSinceEpoch)));
  }

  /// Restores [entry] as the queue: the current track and position are
  /// loaded lazily on the next play(). Missing tracks fail through the
  /// per-track error handling, nothing is validated here. Does not touch the
  /// history, so [editHistory] with `promote` first when picking an archived
  /// entry.
  Future<void> restoreHistoryEntry(HistoryEntry entry) async {
    await _replaceQueue(entry.paths.map(mediaItemFor).toList());
    await skipToQueueItem(entry.index);
    await seek(Duration(milliseconds: entry.positionMs));
  }

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
      player.playingStream.listen((playing) {
        _broadcastState(player);
        _progressTimer?.cancel();
        _progressTimer = null;
        if (playing) {
          _progressTimer =
              Timer.periodic(const Duration(seconds: 10), (_) => _saveProgress());
        } else {
          _saveProgress();
        }
      }),
      player.currentIndexStream.listen((index) {
        if (index != null && index < queue.value.length) {
          _queuePosition = index;
          _setMediaItem(queue.value[index].copyWith(duration: player.duration));
          _saveProgress();
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
      // seek gives Android Auto and the notification a seek bar
      systemActions: const {MediaAction.seek},
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
    _progressTimer?.cancel();
    _progressTimer = null;
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
        initialPosition: _resumePosition,
      );
      _resumePosition = Duration.zero;
    } on PlayerException catch (err) {
      // already reported through errorStream
      developer.log("loading queue failed: $err", name: 'seraph.media_player', error: err);
    } on PlayerInterruptedException {
      // superseded by a newer load
    }
  }

  Future<bool>? _restoring;

  /// Cold start: sources are authenticated, so history is only restored once
  /// the login session is.
  Future<bool> _loggedIn() => sessionReady?.call() ?? Future.value(true);

  /// Completes true once the login session is restored; false when there is
  /// none. Set by main(), which creates this handler before LoginController.
  /// Unset (tests, no login) means ready.
  Future<bool> Function()? sessionReady;

  /// Idle play(): restores the current history entry into the empty queue.
  /// False when there is nothing to resume. Concurrent calls share one restore.
  Future<bool> _restoreCurrent() async {
    if (!await _loggedIn()) {
      return false;
    }
    await loadHistory();
    final current = history.value.current;
    if (current == null) {
      return false;
    }
    await restoreHistoryEntry(current);
    return queue.value.isNotEmpty;
  }

  /// Resumption card, prepare step: restore the current entry without playing.
  @override
  Future<void> prepare() async {
    if (queue.value.isEmpty) {
      await (_restoring ??= _restoreCurrent().whenComplete(() => _restoring = null));
    }
  }

  @override
  Future<void> prepareFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    if (mediaId == _resumeId) {
      await prepare();
    }
  }

  @override
  Future<void> play() async {
    if (queue.value.isEmpty) {
      final restored = await (_restoring ??= _restoreCurrent().whenComplete(() => _restoring = null));
      if (!restored) {
        return;
      }
    }
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
    _saveProgress();
    // the queue survives stop(); the next play() reloads it from here
    final player = _player;
    if (player != null && player.audioSource != null) {
      _resumePosition = player.position;
    }
    await _player?.stop();
    await _disposePlayer();
    await super.stop();
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    final paths = _pathsOf(queue);
    if (paths != null) {
      // store the old playlist's final position, then start the new one,
      // before the player's stop events can write the new queue over it
      _saveProgress();
      unawaited(editHistory((state) => _historyModel.replace(
          state,
          HistoryEntry(
              paths: paths,
              index: 0,
              positionMs: 0,
              lastPlayed: DateTime.now().millisecondsSinceEpoch))));
    }
    await _replaceQueue(queue);
  }

  /// True while the player winds down the old queue: its events would save
  /// the old position against the new queue.
  bool _replacingQueue = false;

  Future<void> _replaceQueue(List<MediaItem> queue) async {
    // The file viewer's Play button keeps its behaviour: replace the queue and
    // load it lazily on the next play().
    _replacingQueue = true;
    try {
      final next = _queueModel.replace(_state, queue, 0);
      _resumePosition = Duration.zero;
      _publish(next);
      await _player?.stop();
      await _player?.clearAudioSources();
    } finally {
      _replacingQueue = false;
    }
  }

  @override
  Future<void> addQueueItems(List<MediaItem> mediaItems) async {
    if (mediaItems.isEmpty) {
      return;
    }
    final next = _queueModel.append(_state, mediaItems);
    _publish(next);
    _saveProgress();
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
    _saveProgress();
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
    _saveProgress();

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
    _saveProgress();
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
      _resumePosition = Duration.zero;
      _saveProgress();
      return;
    }
    await player.seek(Duration.zero, index: index);
  }

  static const String _queueChildPrefix = 'queue/';
  static const String _queueFolderId = 'queue';
  static const String _historyFolderId = 'history';
  static const String _historyChildPrefix = 'history/';

  /// Android Auto opens into this browse tree when nothing is playing. The
  /// root has two folders: the current queue (child ids carry the queue
  /// index, since a file may be queued twice) and the recent playlists
  /// (`history/0` is the current entry, `history/<i>` archive entry i-1).
  // ponytail: queue and history only, real file browsing is a later iteration
  @override
  Future<List<MediaItem>> getChildren(String parentMediaId,
      [Map<String, dynamic>? options]) async {
    if (parentMediaId == AudioService.browsableRootId) {
      return const [
        MediaItem(id: _queueFolderId, title: 'Current queue', playable: false),
        MediaItem(id: _historyFolderId, title: 'Recent playlists', playable: false),
      ];
    }
    if (parentMediaId == AudioService.recentRootId) {
      // Android's media-resumption card: the current entry as one playable item
      await loadHistory();
      final current = history.value.current;
      return current == null ? [] : [_resumeItem(current)];
    }
    if (parentMediaId == _historyFolderId) {
      await loadHistory();
      final state = history.value;
      final now = DateTime.now();
      MediaItem child(int i, HistoryEntry e) {
        final label = historyLabel(e, now);
        final title = historyTitle(e);
        // no artUri: Auto loads browse art itself and cannot send our token
        return MediaItem(
          id: '$_historyChildPrefix$i',
          title: title,
          artist: label.substring(title.length).replaceFirst(' · ', ''),
        );
      }

      return [
        if (state.current != null) child(0, state.current!),
        for (var i = 0; i < state.archive.length; i++) child(i + 1, state.archive[i]),
      ];
    }
    if (parentMediaId != _queueFolderId) {
      return [];
    }
    final entries = queue.value;
    return [
      for (var i = 0; i < entries.length; i++)
        // no artUri: Auto loads browse art itself and cannot send our token
        MediaItem(
          id: '$_queueChildPrefix$i',
          title: entries[i].title,
          artist: entries[i].artist,
          album: entries[i].album,
          duration: entries[i].duration,
        ),
    ];
  }

  static const String _resumeId = 'history/0';

  MediaItem _resumeItem(HistoryEntry e) => MediaItem(
      id: _resumeId, title: historyTitle(e), artist: historyLabel(e, DateTime.now()).substring(historyTitle(e).length).replaceFirst(' · ', ''));

  ValueStream<Map<String, dynamic>>? _rootChildren;
  ValueStream<Map<String, dynamic>>? _queueChildren;
  ValueStream<Map<String, dynamic>>? _historyChildren;

  @override
  ValueStream<Map<String, dynamic>> subscribeToChildren(String parentMediaId) {
    switch (parentMediaId) {
      case AudioService.browsableRootId:
        return _rootChildren ??= BehaviorSubject.seeded(<String, dynamic>{});
      case _queueFolderId:
        return _queueChildren ??=
            queue.map((_) => <String, dynamic>{}).shareValueSeeded(<String, dynamic>{});
      case _historyFolderId:
        return _historyChildren ??=
            history.map((_) => <String, dynamic>{}).shareValueSeeded(<String, dynamic>{});
    }
    return super.subscribeToChildren(parentMediaId);
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    if (mediaId.startsWith(_historyChildPrefix)) {
      await _playHistory(int.tryParse(mediaId.substring(_historyChildPrefix.length)));
      return;
    }
    if (!mediaId.startsWith(_queueChildPrefix)) {
      return;
    }
    final index = int.tryParse(mediaId.substring(_queueChildPrefix.length));
    if (index == null || index < 0 || index >= queue.value.length) {
      return;
    }
    await skipToQueueItem(index);
    await play();
  }

  Future<void> _playHistory(int? index) async {
    if (!await _loggedIn()) {
      return;
    }
    await loadHistory();
    final state = history.value;
    if (index == null || index < 0 || index > state.archive.length) {
      return;
    }
    if (index == 0 && state.current == null) {
      return;
    }
    if (index > 0) {
      await editHistory((s) => _historyModel.promote(s, index - 1));
    }
    await restoreHistoryEntry(history.value.current!);
    await play();
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
    final player = _player;
    if (player == null || player.audioSource == null) {
      _resumePosition = position;
      _saveProgress();
      return;
    }
    await player.seek(position);
  }
}
