# 03 — File viewer + both-viewer integration and build gates

**What to build:** extend the web path to the file viewer's image pages
(the same `HdrPhotoPage`-shaped branch the gallery got on Android, fed by
`FileService.fetchFileBytes`, Hero still dropped on this path), and run
the whole workstream's acceptance: one coherent browser session through
both viewers, then the repo's mandatory gates. Nothing in the Android or
iOS paths may change.

**Blocked by:** 01 — Web tracer bullet; 02 — Pinch zoom and pan via CSS
transform.

**Status:** implemented (browser checklist pending human run)

## Answer

Automated gates against the finished branch (Linux host, Flutter SDK at
`/home/vortex/Development/flutter/flutter`):

- [x] A file-viewer image page renders through the web path; paging and
      zoom/pan behave as in the gallery. *(same `HdrPhotoPageWeb`
      contract; code complete — pop and feel need the checklist below)*
- [x] Backgrounded tab and refocused tab come back correct. *(blob URLs
      live in page state; no window-level calls to lose — verified by
      code review of the lifecycle, browser confirmation below)*
- [x] `flutter analyze` — zero issues; `flutter test` — 362 pass; web
      release build succeeds; Android APK build succeeds (native paths
      compile untouched).
- [ ] Browser checklist (Chrome HDR-on/off, Firefox, Safari 26 if
      available — render, paging, tap, pinch, pan, error state, both
      viewers) against the deployed build.
- [ ] No behaviour change on Android/iOS: the native path's own
      checklist (`.scratch/hdr-photo-viewer/issues/05`) still passes.
