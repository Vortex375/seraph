# 04 — Sort-order pill for text search

**What to build:** Bring back ticket 01's relevance order, behind `GalleryAiFilter.byRelevance` (default
false). While a text pill is shown, `_FilterChipsBar` shows a sort pill ("Newest first" / "Best match")
that toggles it without a new search. `applyAi` keeps the choice while text stays and drops it with the
text. The date heading and scrubber hide while `filter.ranked`, each in its own `Obx` so a toggle alone
updates them. The `gallery-ai` score cutoff from ticket 03 stays.

See [spec](../spec.md), "Ordering".

**Acceptance:**
- Mirror: with `byRelevance` and text, key order (also with more than 999 keys); without text, the flag is
  ignored.
- `applyAi`: date by default; the choice survives a tag change and resets when the text goes.
- Widget test: pill appears with text, toggles order and the scrubber, disappears with the text pill.
- Gates: `flutter analyze` with zero issues, `flutter test`, `flutter build web --release --base-href=/app/`.

**Blocked by:** 03

**Status:** resolved
