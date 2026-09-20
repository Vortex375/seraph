# 03 — File viewer + both-viewer integration and build gates

**What to build:** extend the web path to the file viewer's image pages
(the same `HdrPhotoPage`-shaped branch the gallery got on Android, fed by
`FileService.fetchFileBytes`, Hero still dropped on this path), and run
the whole workstream's acceptance: one coherent browser session through
both viewers, then the repo's mandatory gates. Nothing in the Android or
iOS paths may change.

**Blocked by:** 01 — Web tracer bullet; 02 — Pinch zoom and pan via CSS
transform.

**Status:** ready-for-agent

- [ ] A file-viewer image page (Cloud Files → image file) renders
      through the web path with HDR pop on a gain-map photo; paging
      through image files works; zoom/pan behave as in the gallery.
- [ ] Both viewers: backgrounded tab and refocused tab come back correct
      (blob URLs survive a normal tab lifecycle).
- [ ] Browser checklist recorded under an `## Answer` heading: Chrome
      HDR-on (pop), Chrome HDR-off (SDR base), Firefox (SDR base),
      Safari 26 if available — for render, paging, tap, pinch, pan, and
      an error-state case in each viewer.
- [ ] `flutter analyze` reports zero issues; `flutter test` passes; the
      web release build (`--base-href=/app/`) succeeds; the Android APK
      build succeeds (the photo page gained a web branch; confirm the
      native paths compile untouched).
- [ ] No behaviour change on Android/iOS: the native path's own
      checklist (`.scratch/hdr-photo-viewer/issues/05`) still passes.
