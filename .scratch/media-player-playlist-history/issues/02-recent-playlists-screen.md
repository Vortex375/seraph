# 02: Recent playlists screen

**What to build:** A "Recent playlists" screen listing the current playlist and the archive. It is
reachable from the app bar's navigation dropdown and from a history button in the "now playing" / queue
view. Rows are labeled from their contents, expand to show their tracks, and offer Play, Add to queue
and Delete. See "Recent playlists screen" in `../spec.md`.

**Blocked by:** 01: History model, persistence and recording

**Status:** resolved

- [x] A new route, added to `_buildDropdown` in `app_bar.dart` as "Recent playlists". It works when nothing is playing.
- [x] The "now playing" / queue view has a button that opens the same screen.
- [x] The current entry is listed first and marked as current, followed by the archive, newest first.
- [x] Label: the parent folder's name when every track shares one folder, otherwise the first track's title or file name, then "· N tracks · <relative time>".
- [x] Tapping a row expands it to its track list (file names, or tags where `ensureTags` already has them; no extra tag fetching).
- [x] Play promotes the entry, restores it at its saved track and position, and plays. The previously current playlist appears at the top of the archive.
- [x] Add to queue appends the entry's tracks via `enqueue(paths, playNext: false)`. This counts as an edit of the current playlist and archives nothing.
- [x] Delete (swipe or menu) removes an archived entry. It isn't offered on the current entry.
- [x] The screen updates when the history changes while it is open.
- [x] Gates: `flutter analyze` reports zero issues; `flutter test`; `flutter build web --release --base-href=/app/`.

## Comments

Built: `history_view.dart` (route `/history`, `HistoryView`; StreamBuilder on `handler.history`, expandable rows with Play / Add to queue, swipe-to-delete on archived rows only), `history_label.dart` (pure `historyLabel(entry, now)` / `historyTitle(entry)`, test in `test/media_player/history_label_test.dart`), registered in `app.dart`, dropdown item in `app_bar.dart`, history button in `audio_player_view.dart`. Track lists show file names only (no tag lookup). Play stays on the screen.
