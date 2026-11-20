# 01: History model, persistence and recording

**What to build:** The pure Dart history model (current entry plus archive of 10), its `get_storage`
persistence, and the wiring that records the history as the user plays: a full replace archives, edits
update the current entry, the resume point is saved continuously, and logout clears it. The store and the
restore logic live where `MyAudioHandler` reaches them without the controller, because tickets 03–05
restore from the handler. No UI in this ticket. See "History model", "Persistence" and "Wiring into the
player" in `../spec.md`.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] A history model next to `queue_model.dart` with no Flutter, GetX or just_audio imports. It has `replace`, `updateCurrent`, `promote` and `delete`, each returning a new state.
- [x] `replace` archives the current entry at the top and caps the archive at 10, dropping the oldest. A replace with an identical track list (same paths, same order) archives nothing and only takes the new index and position.
- [x] `promote` makes the picked archive entry current and archives the previous current entry at the top.
- [x] An entry holds `paths` (the paths `setPlaylist` and `enqueue` take, not `MediaItem.id` URLs), `index`, `positionMs` and `lastPlayed`. The state round-trips through JSON.
- [x] The state is stored under one `get_storage` key and survives an app restart.
- [x] `setPlaylist` calls `replace`. `enqueue`, `move` and `removeAt` call `updateCurrent` with the queue after the edit.
- [x] Removing the last remaining track, `closePlayer` and `stop()` leave the stored entry at its last non-empty snapshot.
- [x] The current entry's index and position are saved on pause, stop and track change, and every ~10 s while playing.
- [x] A restore operation (queue + `skipToQueueItem(index)` + `seek(position)`) is callable from the handler. Missing tracks go through the existing per-track error handling; nothing is validated upfront.
- [x] Logout erases the history key.
- [x] Unit tests for the model: replace archives; the cap drops the oldest; identical replace; promote; delete; empty history; JSON round trip.
- [x] Gates: `flutter analyze` reports zero issues; `flutter test`; `flutter build web --release --base-href=/app/`.

## Comments

Built (app/seraph_app/lib/src/media_player/):
- `history_model.dart`: pure `HistoryEntry`, `HistoryState` (`current`, `archive`, JSON) and `HistoryModel` (`replace`, `updateCurrent`, `promote`, `delete`; `archiveSize` 10). Tests in `test/media_player/history_model_test.dart`.
- `history_store.dart`: `HistoryStore` over its own get_storage box (`SeraphPlaylistHistory`, key `playlistHistory`); opened lazily by the handler because the handler is created before SettingsController.
- `audio_handler.dart` records the history itself (the controller is not involved): `updateQueue` = `replace`; `addQueueItems`/`insertQueueItem`/`removeQueueItemAt`/`moveQueueItem` = `updateCurrent`; progress saved on pause/stop/track change/`skipToQueueItem`/`seek`-before-load and every 10 s while playing. An empty queue never writes.
- `login_controller.dart` logout calls `handler.clearHistory()`.

API for tickets 02-05 (all on `MyAudioHandler`):
- `history`: `BehaviorSubject<HistoryState>` (seeded empty until loaded).
- `Future<void> loadHistory()`: reads storage into `history`; call before reading it on a cold start.
- `Future<void> editHistory(HistoryState Function(HistoryState))`: serialized, stored, published. Use with `HistoryModel().promote/delete`.
- `Future<void> restoreHistoryEntry(HistoryEntry)`: queue + `skipToQueueItem(index)` + `seek(position)`; does not touch history (promote first for an archived entry); position is applied on the lazy load via `_resumePosition`.
- `Future<void> clearHistory()`.
- `MediaItem mediaItemFor(String path)`: moved here from the controller (uses `Get.find<FileService>()`), so the handler can build items without the controller.

Deviations: recording lives in the handler, not the controller's setPlaylist/enqueue/move/removeAt (same behaviour, also covers Android Auto edits). A queue containing an item without `extras['path']` is not recorded. Cold-start token wait, idle play(), UI and Android Auto untouched.
