/// Pure Dart queue bookkeeping: the order of queue entries and which one is
/// current. No Flutter, GetX or just_audio imports - this is the test seam for
/// every index rule the handler applies to the just_audio playlist.
class QueueState<T> {
  final List<T> entries;
  final int currentIndex;

  const QueueState(this.entries, this.currentIndex);
}

class QueueModel<T> {
  const QueueModel();

  /// The first entry becomes current when nothing was current (or the queue
  /// was empty), so the caller can start playback at [QueueState.currentIndex].
  QueueState<T> append(QueueState<T> state, List<T> added) {
    if (added.isEmpty) {
      return state;
    }
    return QueueState(
      [...state.entries, ...added],
      state.currentIndex < 0 ? 0 : state.currentIndex,
    );
  }

  QueueState<T> playNext(QueueState<T> state, List<T> added) {
    if (added.isEmpty) {
      return state;
    }
    final at = state.currentIndex < 0 ? 0 : state.currentIndex + 1;
    final entries = [...state.entries]..insertAll(at, added);
    return QueueState(entries, state.currentIndex < 0 ? 0 : state.currentIndex);
  }

  QueueState<T> move(QueueState<T> state, int from, int to) {
    final length = state.entries.length;
    if (from < 0 || from >= length || to < 0 || to >= length || from == to) {
      return state;
    }
    final entries = [...state.entries];
    entries.insert(to, entries.removeAt(from));

    var current = state.currentIndex;
    if (current == from) {
      current = to;
    } else if (from < current && to >= current) {
      current--;
    } else if (from > current && to <= current) {
      current++;
    }
    return QueueState(entries, current);
  }

  QueueState<T> removeAt(QueueState<T> state, int index) {
    if (index < 0 || index >= state.entries.length) {
      return state;
    }
    final entries = [...state.entries]..removeAt(index);
    if (entries.isEmpty) {
      return QueueState(entries, -1);
    }

    final current = state.currentIndex;
    if (current < 0) {
      return QueueState(entries, -1);
    }
    if (index < current) {
      return QueueState(entries, current - 1);
    }
    if (index > current) {
      return QueueState(entries, current);
    }
    // Removing the current entry makes the next one current, or the new last
    // entry when the current one was last.
    return QueueState(entries, current < entries.length ? current : entries.length - 1);
  }

  QueueState<T> replace(QueueState<T> state, List<T> entries, int startIndex) {
    if (entries.isEmpty) {
      return QueueState(<T>[], -1);
    }
    return QueueState([...entries], startIndex.clamp(0, entries.length - 1));
  }
}
