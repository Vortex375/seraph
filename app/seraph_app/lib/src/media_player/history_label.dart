import 'package:path/path.dart' as p;

import 'history_model.dart';

/// The folder name when every track shares one folder, otherwise the first
/// track's file name. No Flutter imports: Android Auto reuses it.
String historyTitle(HistoryEntry entry) {
  final paths = entry.paths;
  if (paths.isEmpty) {
    return '';
  }
  final folder = p.url.dirname(paths.first);
  if (paths.every((path) => p.url.dirname(path) == folder)) {
    final name = p.url.basename(folder);
    if (name.isNotEmpty && name != '.') {
      return name;
    }
  }
  return p.url.basename(paths.first);
}

/// Row label: title, track count, relative time.
String historyLabel(HistoryEntry entry, DateTime now) {
  final n = entry.paths.length;
  final tracks = n == 1 ? '1 track' : '$n tracks';
  final age = now.difference(DateTime.fromMillisecondsSinceEpoch(entry.lastPlayed));
  return '${historyTitle(entry)} · $tracks · ${_relative(age)}';
}

String _relative(Duration age) {
  if (age.inMinutes < 1) return 'just now';
  if (age.inHours < 1) return '${age.inMinutes} min ago';
  if (age.inDays < 1) return '${age.inHours} h ago';
  return '${age.inDays} d ago';
}
