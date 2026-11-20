# 05: Recent playlists in Android Auto

**What to build:** The Android Auto browse root gets two browsable folders: **Current queue** (today's
`queue/<i>` children, moved one level down) and **Recent playlists** (one playable child per history
entry, id `history/<i>`). Playing a history child promotes and plays that entry. See "Android Auto
browse tree" in `../spec.md`.

**Blocked by:** 01: History model, persistence and recording

**Status:** resolved

- [x] `getChildren(browsableRootId)` returns the two folders. The Current queue folder lists today's `queue/<i>` children, and playing one behaves as today.
- [x] The Recent playlists folder lists the current entry and the archive, labeled as on the Recent playlists screen (ticket 02's label rule; share the function). No `artUri`, as for queue children.
- [x] `playFromMediaId('history/<i>')` promotes that entry, restores it at its saved track and position, and plays.
- [x] `subscribeToChildren` notifies the Recent playlists folder when the history changes, as it already does for the queue.
- [x] Gates: `flutter analyze` reports zero issues; `flutter test`; `flutter build web --release --base-href=/app/`; `flutter build apk` if `android/` was touched.

## Comments

Implemented in audio_handler.dart: root returns `queue` and `history` folders; `history/0` is the current entry, `history/<i>` archive i-1 (ids stay stable if current is null: archive starts at 1). Subtitle (artist) is the label minus the title, from `historyLabel`/`historyTitle`. `playFromMediaId('history/<i>')` promotes then restores and plays. The root stream is now static; `queue` and `history` folders each have their own stream. No android/ change, so no APK build. Existing browse test moved to the `queue` folder. Tests in audio_handler_history_test.dart (`browseTests`).
