# 01 — AI filter part and relevance order in the mirror

**What to build:** In `mirror/gallery_mirror.dart`, replace `GalleryPersonFilter` with `GalleryAiFilter`
(text, tag, person and keys in score order), and replace `GalleryFilter.person` with `GalleryFilter.ai`
(`copyWith(ai:, clearAi:)`, plus `ranked => ai?.text != null`). Text, tag and person each count as one in
`activeCount`.

In `_filterPredicate`, the existing `_InJsonArray` clause reads from `ai.keys`. When `filter.ranked`,
`queryPage`/`queryItems` sort by the `json_each` index of `provider_id || '\u001f' || path`.
`GalleryGridController.reload` skips `_buildMonthBoundaries` when `ranked`.

In `GallerySearchController`, `filterByPerson` becomes `applyAi(grid, {text, tag, person})`. It sends one
`service.search(q:, tag:, personId:, limit: 1000)` request, guards against stale responses with
`_generation`, and leaves the filter unchanged on failure. Update the two existing `filterByPerson` callers
(`gallery_view.dart` `_pickPerson`, `gallery_people_view.dart`) and the "AI went away" listener (clear `ai`).

See [spec](../spec.md) for the reasons and the ordering rule.

**Acceptance:**
- Mirror unit tests:
  - With `ai.text` set, the result is in key order, intersected with Place and date.
  - With only a tag or person, the result is in Capture Date order.
  - More than 999 keys still work.
- `applyAi` tests with a fake service: one combined request; the filter is unchanged on failure; the
  newest call wins.
- The person filter behaves as before.
- Gates: `flutter analyze` with zero issues, `flutter test`, `flutter build web --release --base-href=/app/`.

**Blocked by:** —

**Status:** resolved
