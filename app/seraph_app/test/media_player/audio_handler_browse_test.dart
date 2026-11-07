import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/media_player/audio_handler.dart';

/// Android Auto's browse tree: the root lists the queue, with index-based ids
/// so a file queued twice stays distinguishable.
void main() {
  test('root lists the queue with index ids and no art', () async {
    final handler = MyAudioHandler();
    await handler.updateQueue([
      MediaItem(id: 'u/a', title: 'A', artUri: Uri.parse('https://x/a')),
      const MediaItem(id: 'u/a', title: 'A again'),
    ]);

    final children = await handler.getChildren(AudioService.browsableRootId);
    expect(children.map((c) => c.id), ['queue/0', 'queue/1']);
    expect(children.map((c) => c.title), ['A', 'A again']);
    expect(children.first.artUri, isNull);
    expect(children.every((c) => c.playable ?? false), isTrue);

    expect(await handler.getChildren('queue/0'), isEmpty);
  });

  test('root children notify on queue changes', () async {
    final handler = MyAudioHandler();
    final events = <Map<String, dynamic>>[];
    final sub = handler.subscribeToChildren(AudioService.browsableRootId).listen(events.add);
    await handler.updateQueue([const MediaItem(id: 'u/a', title: 'A')]);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(events, isNotEmpty);
  });
}
