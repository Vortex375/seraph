# 01: Material 3 seek bar with buffered track

**What to build:** The "now playing" seek bar uses the current (December 2023) Material 3 slider design
and shows the buffered position as a secondary track. Dragging scrubs locally and seeks once, on
release. The mini player's progress bar uses the matching current Material 3 progress indicator. See
"Seek bar (app)" in `../spec.md`.

**Blocked by:** None (can start immediately)

**Status:** resolved

- [x] The "now playing" slider renders in the current Material 3 design (`year2023: false`, via `SliderThemeData` in the app theme or the per-widget flag).
- [x] The slider's `secondaryTrackValue` shows the buffered position. The controller exposes `bufferedPosition` from the handler's `playbackState`.
- [x] Dragging updates the thumb and the time label without seeking. A single seek is issued on release (`onChangeEnd`).
- [x] The elapsed / total time label still shows and is correct for tracks whose duration is not yet known. The slider doesn't throw when duration is null or position passes duration.
- [x] The mini player's `LinearProgressIndicator` uses the current Material 3 design.
- [x] Gates: `flutter analyze` reports zero issues; `flutter test`; `flutter build web --release --base-href=/app/`.

## Comments

Implemented in `644c81b` (+ review fixes in `ac5c8c5`). Theme-level
`SliderThemeData(year2023: false)` / `ProgressIndicatorThemeData(year2023: false)`
in `app.dart` (the setter is deprecated but remains the only theme route in
Flutter 3.47); drag state kept local in `_AudioPlayerViewState`, one seek on
release. Skipped a widget test for the slider (spec: widgets are verified
on-device, ticket 06).
