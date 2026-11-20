# 03: Idle play resumes the most recent playlist

**What to build:** When `MyAudioHandler.play()` is called with an empty queue while the app is running
(notification, lock screen, headset, Android Auto, remote control), it restores the current history
entry at its saved track and position and plays it. With no history, it does nothing, as today. See
"Idle play and cold start" in `../spec.md`. Cold start is ticket 04.

**Blocked by:** 01: History model, persistence and recording

**Status:** resolved

- [x] `play()` with an empty queue and a stored current entry restores that entry and plays from the saved track and position.
- [x] `play()` with an empty queue and no history does nothing and doesn't throw.
- [x] `play()` with a non-empty queue behaves exactly as today.
- [x] After closing the player with the close button, a play command resumes the same playlist where it stopped.
- [x] Resuming doesn't archive anything (it is not a replace).
- [ ] Gates: `flutter analyze` reports zero issues; `flutter test`; `flutter build web --release --base-href=/app/` (web build left to the orchestrator).

## Comments

`play()` with an empty queue awaits `loadHistory()`, restores `history.value.current` via `restoreHistoryEntry` (no history write), then continues into the normal play path; no history returns silently. A shared `_restoring` future stops two racing play() calls from restoring twice. A marked spot in `play()` is left for the ticket 04 login wait. `stop()` (close button) now keeps the player position in `_resumePosition`, since the queue survives stop() and the next play() reloads it from there. Tests (`audio_handler_history_test.dart`) mock the path_provider and just_audio channels; the platform-less player reports index 0 on creation, so the saved index/position are asserted through `restoreHistoryEntry`, not through `play()`. Not covered: real audio start after restore, the stop()-then-play position resume.
