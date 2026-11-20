import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/media_player/history_model.dart';

/// The history model is the test seam for every archive rule.
void main() {
  const model = HistoryModel();

  HistoryEntry entry(List<String> paths, {int index = 0, int positionMs = 0}) =>
      HistoryEntry(paths: paths, index: index, positionMs: positionMs, lastPlayed: 1);

  group('replace', () {
    test('empty history: becomes current, nothing archived', () {
      final result = model.replace(const HistoryState(), entry(['a']));
      expect(result.current!.paths, ['a']);
      expect(result.archive, isEmpty);
    });

    test('archives the current entry at the top', () {
      var state = model.replace(const HistoryState(), entry(['a']));
      state = model.replace(state, entry(['b']));
      state = model.replace(state, entry(['c']));
      expect(state.current!.paths, ['c']);
      expect(state.archive.map((e) => e.paths.first), ['b', 'a']);
    });

    test('the cap drops the oldest', () {
      var state = const HistoryState();
      for (var i = 0; i < 13; i++) {
        state = model.replace(state, entry(['t$i']));
      }
      expect(state.archive, hasLength(10));
      expect(state.archive.first.paths, ['t11']);
      expect(state.archive.last.paths, ['t2']);
    });

    test('identical track list archives nothing, takes index and position', () {
      var state = model.replace(const HistoryState(), entry(['a', 'b']));
      state = model.replace(state, entry(['a', 'b'], index: 1, positionMs: 500));
      expect(state.archive, isEmpty);
      expect(state.current!.index, 1);
      expect(state.current!.positionMs, 500);
    });

    test('same paths in another order is a new playlist', () {
      var state = model.replace(const HistoryState(), entry(['a', 'b']));
      state = model.replace(state, entry(['b', 'a']));
      expect(state.archive, hasLength(1));
    });
  });

  group('updateCurrent', () {
    test('replaces the current entry without archiving', () {
      var state = model.replace(const HistoryState(), entry(['a']));
      state = model.updateCurrent(state, ['a', 'b'], 1, 700, 9);
      expect(state.current!.paths, ['a', 'b']);
      expect(state.current!.index, 1);
      expect(state.current!.positionMs, 700);
      expect(state.current!.lastPlayed, 9);
      expect(state.archive, isEmpty);
    });

    test('empty history: creates the current entry', () {
      final state = model.updateCurrent(const HistoryState(), ['a'], 0, 0, 9);
      expect(state.current!.paths, ['a']);
    });
  });

  group('promote', () {
    test('picked entry becomes current, previous current archived at the top', () {
      var state = const HistoryState();
      for (final t in ['a', 'b', 'c']) {
        state = model.replace(state, entry([t]));
      }
      // current c, archive [b, a]
      state = model.promote(state, 1);
      expect(state.current!.paths, ['a']);
      expect(state.archive.map((e) => e.paths.first), ['c', 'b']);
    });

    test('out of range changes nothing', () {
      final state = model.replace(const HistoryState(), entry(['a']));
      expect(model.promote(state, 0), same(state));
    });
  });

  group('delete', () {
    test('removes the archive entry only', () {
      var state = const HistoryState();
      for (final t in ['a', 'b', 'c']) {
        state = model.replace(state, entry([t]));
      }
      state = model.delete(state, 0);
      expect(state.current!.paths, ['c']);
      expect(state.archive.map((e) => e.paths.first), ['a']);
    });

    test('out of range changes nothing', () {
      const state = HistoryState();
      expect(model.delete(state, 0), same(state));
    });
  });

  test('empty history round trips', () {
    final back = HistoryState.fromJson(
        jsonDecode(jsonEncode(const HistoryState().toJson())) as Map<String, dynamic>);
    expect(back.current, isNull);
    expect(back.archive, isEmpty);
  });

  test('JSON round trip', () {
    var state = model.replace(const HistoryState(), entry(['a', 'b'], index: 1, positionMs: 42));
    state = model.replace(state, entry(['c']));
    final back = HistoryState.fromJson(
        jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>);
    expect(back.current!.paths, ['c']);
    expect(back.archive.single.paths, ['a', 'b']);
    expect(back.archive.single.index, 1);
    expect(back.archive.single.positionMs, 42);
    expect(back.archive.single.lastPlayed, 1);
  });
}
