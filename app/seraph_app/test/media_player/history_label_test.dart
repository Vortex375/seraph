import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/media_player/history_label.dart';
import 'package:seraph_app/src/media_player/history_model.dart';

HistoryEntry _entry(List<String> paths, DateTime played) => HistoryEntry(
    paths: paths, index: 0, positionMs: 0, lastPlayed: played.millisecondsSinceEpoch);

void main() {
  final now = DateTime(2026, 1, 10, 12);

  test('shared folder names the entry', () {
    final e = _entry(['/Music/Album/a.mp3', '/Music/Album/b.mp3'],
        now.subtract(const Duration(minutes: 5)));
    expect(historyLabel(e, now), 'Album · 2 tracks · 5 min ago');
  });

  test('mixed folders use the first file name', () {
    final e = _entry(['/Music/A/a.mp3', '/Music/B/b.mp3'],
        now.subtract(const Duration(days: 2)));
    expect(historyLabel(e, now), 'a.mp3 · 2 tracks · 2 d ago');
  });

  test('single track and just now', () {
    final e = _entry(['/Music/x.mp3'], now);
    expect(historyLabel(e, now), 'Music · 1 track · just now');
  });
}
