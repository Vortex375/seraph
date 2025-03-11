import 'package:audio_service/audio_service.dart';
import 'package:media_kit/media_kit.dart';

class MyAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {

  final _player = Player();

  MyAudioHandler() : super() {
    _player.stream.playlist.listen((pl) {
      if (queue.value.isEmpty) {
        mediaItem.add(null);
      } else {
        mediaItem.add(queue.value[pl.index]);
      }
      playbackState.add(playbackState.value.copyWith(
        queueIndex: pl.index
      ));
    });
    _player.stream.playing.listen((playing) {
      playbackState.add(playbackState.value.copyWith(
        processingState: playing ? AudioProcessingState.ready : AudioProcessingState.idle,
        playing: playing
      ));
    });
    _player.stream.error.listen((err) {
      playbackState.add(playbackState.value.copyWith(
        processingState: AudioProcessingState.error,
        errorMessage: err
      ));
    });

  }

  @override
  Future<void> play() async {
    await _player.play();
  }

  @override
  Future<void> pause() async {
    await _player.pause();
  }

  @override
  Future<void> stop() async {
    await _player.stop();
  }

  @override
  Future<void> updateQueue(List<MediaItem> newQueue) async {
    super.updateQueue(newQueue);
    final pl = Playlist(
      newQueue.map((i) => Media(
        i.id,
        httpHeaders: i.extras?.map((k, v) => MapEntry(k, v.toString()))
      )).toList(),
    );

    await _player.open(pl);
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    await _player.jump(index);
  }
}