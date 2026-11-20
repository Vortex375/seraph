/// Pure Dart playlist history: the current playlist plus the most recent
/// archived ones. No Flutter, GetX or just_audio imports - this is the test
/// seam for every archive rule. Every operation returns the new state.
class HistoryEntry {
  /// The file paths [setPlaylist]/[enqueue] take, not `MediaItem.id` URLs.
  final List<String> paths;
  final int index;
  final int positionMs;

  /// Epoch milliseconds.
  final int lastPlayed;

  const HistoryEntry({
    required this.paths,
    required this.index,
    required this.positionMs,
    required this.lastPlayed,
  });

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        paths: List<String>.from(json['paths'] as List),
        index: json['index'] as int,
        positionMs: json['positionMs'] as int,
        lastPlayed: json['lastPlayed'] as int,
      );

  Map<String, dynamic> toJson() => {
        'paths': paths,
        'index': index,
        'positionMs': positionMs,
        'lastPlayed': lastPlayed,
      };

  bool hasSamePaths(List<String> other) {
    if (other.length != paths.length) {
      return false;
    }
    for (var i = 0; i < paths.length; i++) {
      if (paths[i] != other[i]) {
        return false;
      }
    }
    return true;
  }
}

class HistoryState {
  final HistoryEntry? current;

  /// Newest first.
  final List<HistoryEntry> archive;

  const HistoryState({this.current, this.archive = const []});

  factory HistoryState.fromJson(Map<String, dynamic> json) => HistoryState(
        current: json['current'] == null
            ? null
            : HistoryEntry.fromJson(json['current'] as Map<String, dynamic>),
        archive: [
          for (final e in json['archive'] as List)
            HistoryEntry.fromJson(e as Map<String, dynamic>)
        ],
      );

  Map<String, dynamic> toJson() => {
        'current': current?.toJson(),
        'archive': [for (final e in archive) e.toJson()],
      };
}

class HistoryModel {
  const HistoryModel();

  static const int archiveSize = 10;

  List<HistoryEntry> _archived(HistoryState state) => [
        if (state.current != null) state.current!,
        ...state.archive,
      ].take(archiveSize).toList();

  /// A full queue replace: the current entry moves to the top of the archive
  /// (the oldest is dropped past [archiveSize]). Replacing with the same
  /// paths in the same order archives nothing and only takes the new index
  /// and position.
  HistoryState replace(HistoryState state, HistoryEntry entry) {
    final current = state.current;
    if (current != null && current.hasSamePaths(entry.paths)) {
      return HistoryState(current: entry, archive: state.archive);
    }
    return HistoryState(current: entry, archive: _archived(state));
  }

  /// An edit of the current playlist or a resume-point save.
  HistoryState updateCurrent(HistoryState state, List<String> paths, int index,
      int positionMs, int lastPlayed) {
    return HistoryState(
      current: HistoryEntry(
          paths: paths, index: index, positionMs: positionMs, lastPlayed: lastPlayed),
      archive: state.archive,
    );
  }

  /// Makes archive entry [archiveIndex] current and archives the previous
  /// current entry at the top.
  HistoryState promote(HistoryState state, int archiveIndex) {
    if (archiveIndex < 0 || archiveIndex >= state.archive.length) {
      return state;
    }
    final rest = [...state.archive]..removeAt(archiveIndex);
    return HistoryState(
      current: state.archive[archiveIndex],
      archive: [if (state.current != null) state.current!, ...rest],
    );
  }

  HistoryState delete(HistoryState state, int archiveIndex) {
    if (archiveIndex < 0 || archiveIndex >= state.archive.length) {
      return state;
    }
    return HistoryState(
      current: state.current,
      archive: [...state.archive]..removeAt(archiveIndex),
    );
  }
}
