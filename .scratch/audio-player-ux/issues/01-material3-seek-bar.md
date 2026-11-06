# 01: Material 3 seek bar with buffered track

**What to build:** The "now playing" seek bar uses the current (December 2023) Material 3 slider design
and shows the buffered position as a secondary track. Dragging scrubs locally and seeks once, on
release. The mini player's progress bar uses the matching current Material 3 progress indicator. See
"Seek bar (app)" in `../spec.md`.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] The "now playing" slider renders in the current Material 3 design (`year2023: false`, via `SliderThemeData` in the app theme or the per-widget flag).
- [ ] The slider's `secondaryTrackValue` shows the buffered position. The controller exposes `bufferedPosition` from the handler's `playbackState`.
- [ ] Dragging updates the thumb and the time label without seeking. A single seek is issued on release (`onChangeEnd`).
- [ ] The elapsed / total time label still shows and is correct for tracks whose duration is not yet known. The slider doesn't throw when duration is null or position passes duration.
- [ ] The mini player's `LinearProgressIndicator` uses the current Material 3 design.
- [ ] Gates: `flutter analyze` reports zero issues; `flutter test`; `flutter build web --release --base-href=/app/`.
