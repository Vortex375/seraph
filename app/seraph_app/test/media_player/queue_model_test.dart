import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/media_player/queue_model.dart';

/// The queue model is the app's test seam for index bookkeeping: every edit
/// returns the new order and the index that follows the playing entry.
void main() {
  const model = QueueModel<String>();

  QueueState<String> state(List<String> entries, int currentIndex) =>
      QueueState(entries, currentIndex);

  group('append', () {
    test('empty queue: added tracks at the front, first one current', () {
      final result = model.append(state([], -1), ['a', 'b']);
      expect(result.entries, ['a', 'b']);
      expect(result.currentIndex, 0);
    });

    test('non-empty queue: adds at the end, current unchanged', () {
      final result = model.append(state(['a', 'b'], 1), ['c', 'd']);
      expect(result.entries, ['a', 'b', 'c', 'd']);
      expect(result.currentIndex, 1);
    });
  });

  group('playNext', () {
    test('nothing current: inserts at 0, first inserted is current', () {
      final result = model.playNext(state(['a', 'b'], -1), ['x', 'y']);
      expect(result.entries, ['x', 'y', 'a', 'b']);
      expect(result.currentIndex, 0);
    });

    test('mid-queue: inserts right after the current entry', () {
      final result = model.playNext(state(['a', 'b', 'c'], 1), ['x', 'y']);
      expect(result.entries, ['a', 'b', 'x', 'y', 'c']);
      expect(result.currentIndex, 1);
    });

    test('at the last item: inserts at the end', () {
      final result = model.playNext(state(['a', 'b'], 1), ['x']);
      expect(result.entries, ['a', 'b', 'x']);
      expect(result.currentIndex, 1);
    });

    test('into an empty queue: the inserted track is current', () {
      final result = model.playNext(state([], -1), ['x']);
      expect(result.entries, ['x']);
      expect(result.currentIndex, 0);
    });
  });

  group('move', () {
    test('before the current entry: current follows the playing entry', () {
      final result = model.move(state(['a', 'b', 'c', 'd'], 1), 0, 2);
      expect(result.entries, ['b', 'c', 'a', 'd']);
      expect(result.currentIndex, 0);
    });

    test('across the current entry: current shifts down', () {
      final result = model.move(state(['a', 'b', 'c', 'd'], 1), 3, 0);
      expect(result.entries, ['d', 'a', 'b', 'c']);
      expect(result.currentIndex, 2);
    });

    test('after the current entry: current unchanged', () {
      final result = model.move(state(['a', 'b', 'c', 'd'], 1), 2, 3);
      expect(result.entries, ['a', 'b', 'd', 'c']);
      expect(result.currentIndex, 1);
    });

    test('moving the current entry itself: current moves with it', () {
      final result = model.move(state(['a', 'b', 'c', 'd'], 1), 1, 3);
      expect(result.entries, ['a', 'c', 'd', 'b']);
      expect(result.currentIndex, 3);
    });

    test('invalid indices: unchanged', () {
      final result = model.move(state(['a', 'b'], 0), 0, 5);
      expect(result.entries, ['a', 'b']);
      expect(result.currentIndex, 0);
    });
  });

  group('removeAt', () {
    test('before the current entry: current shifts down', () {
      final result = model.removeAt(state(['a', 'b', 'c', 'd'], 2), 0);
      expect(result.entries, ['b', 'c', 'd']);
      expect(result.currentIndex, 1);
    });

    test('the current entry: the next entry becomes current', () {
      final result = model.removeAt(state(['a', 'b', 'c', 'd'], 2), 2);
      expect(result.entries, ['a', 'b', 'd']);
      expect(result.currentIndex, 2);
    });

    test('after the current entry: current unchanged', () {
      final result = model.removeAt(state(['a', 'b', 'c', 'd'], 2), 3);
      expect(result.entries, ['a', 'b', 'c']);
      expect(result.currentIndex, 2);
    });

    test('the last entry while it is current: the new last becomes current',
        () {
      final result = model.removeAt(state(['a', 'b', 'c'], 2), 2);
      expect(result.entries, ['a', 'b']);
      expect(result.currentIndex, 1);
    });

    test('the only entry: empties the queue', () {
      final result = model.removeAt(state(['a'], 0), 0);
      expect(result.entries, isEmpty);
      expect(result.currentIndex, -1);
    });

    test('invalid index or empty queue: unchanged', () {
      expect(model.removeAt(state(['a'], 0), 3).currentIndex, 0);
      expect(model.removeAt(state([], -1), 0).entries, isEmpty);
    });
  });

  group('replace', () {
    test('replaces the entries and starts at the given index', () {
      final result = model.replace(state(['a'], 0), ['x', 'y', 'z'], 2);
      expect(result.entries, ['x', 'y', 'z']);
      expect(result.currentIndex, 2);
    });

    test('empty replacement empties the queue', () {
      final result = model.replace(state(['a'], 0), [], 0);
      expect(result.entries, isEmpty);
      expect(result.currentIndex, -1);
    });

    test('start index is clamped into range', () {
      expect(model.replace(state([], -1), ['x', 'y'], 5).currentIndex, 1);
      expect(model.replace(state([], -1), ['x', 'y'], -2).currentIndex, 0);
    });
  });
}
