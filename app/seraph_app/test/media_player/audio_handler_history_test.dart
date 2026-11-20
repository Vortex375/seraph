import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/media_player/audio_handler.dart';

MediaItem item(String path) => MediaItem(id: 'u/$path', title: path, extras: {'path': path});

class _FakeFileService implements FileService {
  @override
  String getFileUrl(String path) => 'u/$path';
  @override
  String getAlbumArtUrl(String path) => 'art/$path';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Replacing the queue archives the playlist that was current.
void main() {
  idlePlayTests();
  restoreTests();
  browseTests();
  coldStartTests();
  TestWidgetsFlutterBinding.ensureInitialized();

  test('updateQueue archives the previous playlist and makes the new one current', () async {
    final dir = Directory.systemTemp.createTempSync('seraph_history_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (call) async => dir.path);

    final handler = MyAudioHandler();
    await handler.updateQueue([item('a1'), item('a2')]);
    await handler.skipToQueueItem(1);
    await handler.updateQueue([item('b1')]);
    await handler.skipToQueueItem(0);
    await handler.loadHistory();

    final state = handler.history.value;
    expect(state.current!.paths, ['b1']);
    expect(state.archive.map((e) => e.paths), [
      ['a1', 'a2']
    ]);
    expect(state.archive.single.index, 1);
  });
}

/// Idle play(): the real AudioPlayer is unavailable in tests (no platform
/// plugin), so play() throws after the restore; the queue and history state
/// it leaves behind are what is checked.
void idlePlayTests() {
  late Directory dir;
  setUp(() async {
    Get.put<FileService>(_FakeFileService());
    dir = Directory.systemTemp.createTempSync('seraph_idle_play_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (call) async => dir.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.ryanheise.just_audio.methods'),
        (call) async => call.method == 'disposeAllPlayers' ? <String, dynamic>{} : null);
    await MyAudioHandler().clearHistory(); // get_storage is cached per process
  });
  tearDown(() {
    Get.reset();
    dir.deleteSync(recursive: true);
  });

  Future<void> tryPlay(MyAudioHandler h) async {
    try {
      await h.play();
    } catch (_) {/* no platform player */}
  }

  test('idle play restores the current entry without archiving', () async {
    final seed = MyAudioHandler();
    await seed.updateQueue([item('a1'), item('a2')]);
    await seed.skipToQueueItem(1);
    await seed.seek(const Duration(seconds: 7));
    await seed.history.firstWhere((s) => s.current != null);
    await seed.loadHistory();
    final before = seed.history.value;

    final handler = MyAudioHandler();
    expect(handler.queue.value, isEmpty);
    await tryPlay(handler);

    expect(handler.queue.value.map((e) => e.extras!['path']), ['a1', 'a2']);
    // The saved track and position are checked below through
    // restoreHistoryEntry: the platform-less AudioPlayer reports index 0 as soon
    // as play() creates it, which a real player does not.
    expect(handler.history.value.current!.paths, ['a1', 'a2']);
    expect(handler.history.value.archive, before.archive);
  });

  test('idle play with no history does nothing', () async {
    final handler = MyAudioHandler();
    await handler.play();
    expect(handler.queue.value, isEmpty);
    expect(handler.history.value.current, isNull);
  });
}

void restoreTests() {
  test('restoring an entry selects its saved track and leaves the history alone', () async {
    Get.put<FileService>(_FakeFileService());
    final dir = Directory.systemTemp.createTempSync('seraph_restore_test');
    addTearDown(() {
      Get.reset();
      dir.deleteSync(recursive: true);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (call) async => dir.path);

    final handler = MyAudioHandler();
    await handler.clearHistory();
    await handler.updateQueue([item('a1'), item('a2')]);
    await handler.skipToQueueItem(1);
    await handler.seek(const Duration(seconds: 7));
    await handler.loadHistory();
    final before = handler.history.value;

    final other = MyAudioHandler();
    await other.restoreHistoryEntry(before.current!);
    expect(other.queue.value.map((e) => e.extras!['path']), ['a1', 'a2']);
    expect(other.mediaItem.value?.extras!['path'], 'a2');
    await other.loadHistory();
    expect(other.history.value.current!.index, 1);
    expect(other.history.value.current!.positionMs, 7000);
    expect(other.history.value.archive, before.archive);
  });
}

void browseTests() {
  late Directory dir;
  setUp(() async {
    Get.put<FileService>(_FakeFileService());
    dir = Directory.systemTemp.createTempSync('seraph_browse_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (call) async => dir.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.ryanheise.just_audio.methods'),
        (call) async => call.method == 'disposeAllPlayers' ? <String, dynamic>{} : null);
    await MyAudioHandler().clearHistory();
  });
  tearDown(() {
    Get.reset();
    dir.deleteSync(recursive: true);
  });

  Future<MyAudioHandler> seeded() async {
    final h = MyAudioHandler();
    await h.updateQueue([item('x/a1'), item('x/a2')]);
    await h.updateQueue([item('y/b1')]);
    await h.loadHistory();
    return h;
  }

  test('root lists the two folders, the queue folder lists the queue', () async {
    final h = await seeded();
    final root = await h.getChildren(AudioService.browsableRootId);
    expect(root.map((e) => e.id), ['queue', 'history']);
    expect(root.map((e) => e.title), ['Current queue', 'Recent playlists']);
    expect(root.every((e) => e.playable == false), isTrue);
    expect((await h.getChildren('queue')).map((e) => e.id), ['queue/0']);
  });

  test('history folder lists the current entry first, then the archive', () async {
    final h = await seeded();
    final kids = await h.getChildren('history');
    expect(kids.map((e) => e.id), ['history/0', 'history/1']);
    expect(kids.map((e) => e.title), ['y', 'x']);
    expect(kids[0].artist, '1 track · just now');
    expect(kids[1].artist, '2 tracks · just now');
    expect(kids.every((e) => e.artUri == null), isTrue);
  });

  test('playing history/1 promotes the archived entry and restores it', () async {
    final h = await seeded();
    try {
      await h.playFromMediaId('history/1');
    } catch (_) {/* no platform player */}
    expect(h.history.value.current!.paths, ['x/a1', 'x/a2']);
    expect(h.history.value.archive.map((e) => e.paths), [
      ['y/b1']
    ]);
    expect(h.queue.value.map((e) => e.extras!['path']), ['x/a1', 'x/a2']);
  });

  test('out of range history ids do nothing', () async {
    final h = await seeded();
    await h.playFromMediaId('history/9');
    await h.playFromMediaId('history/x');
    expect(h.history.value.current!.paths, ['y/b1']);
  });
}

void coldStartTests() {
  group('cold start', _coldStartTests);
}

void _coldStartTests() {
  late Directory dir;
  setUp(() async {
    Get.put<FileService>(_FakeFileService());
    dir = Directory.systemTemp.createTempSync('seraph_cold_start_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (call) async => dir.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('com.ryanheise.just_audio.methods'),
        (call) async => call.method == 'disposeAllPlayers' ? <String, dynamic>{} : null);
    final seed = MyAudioHandler();
    await seed.clearHistory();
    await seed.updateQueue([item('a1'), item('a2')]);
    await seed.skipToQueueItem(1);
    await seed.loadHistory();
  });
  tearDown(() {
    Get.reset();
    dir.deleteSync(recursive: true);
  });

  Future<void> tryPlay(MyAudioHandler h) async {
    try {
      await h.play();
    } catch (_) {/* no platform player */}
  }

  test('play() before the login is ready waits, then restores', () async {
    final ready = Completer<bool>();
    final handler = MyAudioHandler()..sessionReady = () => ready.future;
    final played = tryPlay(handler);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(handler.queue.value, isEmpty);

    ready.complete(true);
    await played;
    expect(handler.queue.value.map((e) => e.extras!['path']), ['a1', 'a2']);
  });

  test('play() with no restorable session does nothing', () async {
    final handler = MyAudioHandler()..sessionReady = () async => false;
    await handler.play();
    await handler.playFromMediaId('history/0');
    expect(handler.queue.value, isEmpty);
  });

  test('recent root answers with the current entry; prepare restores it', () async {
    final handler = MyAudioHandler();
    final recent = await handler.getChildren(AudioService.recentRootId);
    expect(recent.map((e) => e.id), ['history/0']);
    expect(recent.single.playable, isNot(false));

    await handler.prepareFromMediaId(recent.single.id);
    expect(handler.queue.value.map((e) => e.extras!['path']), ['a1', 'a2']);
    expect(handler.mediaItem.value?.extras!['path'], 'a2');
  });

  test('recent root is empty without history', () async {
    await MyAudioHandler().clearHistory();
    expect(await MyAudioHandler().getChildren(AudioService.recentRootId), isEmpty);
  });
}
