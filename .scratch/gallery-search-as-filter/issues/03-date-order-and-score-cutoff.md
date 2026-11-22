# 03 — Date order for text search, with a score cutoff

**What to build:** Revert ticket 01's relevance order: the grid stays in Capture Date order whatever the
filter, and the month boundaries, date heading and scrubber are always there (remove `GalleryFilter.ranked`,
`_SpaceKeyRank` and the ranked branches in the mirror, grid controller and view). In `gallery-ai`, add
`Config.SearchMinScore` (`gallery.ai.search.minScore`, default 0.23) and drop text hits whose cosine
distance exceeds `1 - SearchMinScore`.

See [spec](../spec.md), "Ordering".

**Acceptance:**
- `TestSearchTextMinScore`: a hit below the cutoff is dropped; a search without text is unaffected.
- Mirror tests: text keys are membership in Capture Date order.
- Gates: `go test ./...` in `gallery-ai` with the integration tests actually running; `flutter analyze`
  with zero issues, `flutter test`, `flutter build web --release --base-href=/app/`.

**Blocked by:** 02

**Status:** resolved
