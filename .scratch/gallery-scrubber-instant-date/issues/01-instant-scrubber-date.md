# 01 — Instant scrubber date from the local mirror

**What to build:** Dragging the Gallery Mode date scrubber (and the floating
month heading) now shows the correct local-time month for the current position
*instantly*, with no `…` placeholder and no asynchronous lookup. The date is
derived from a one-time month-boundary map built from the local mirror's
`capturedAt` column at the same time the slider's total length is already
computed, so it costs no per-drag work and no page loads.

The controller builds, on `open()`/`reload()`, a list of month boundaries
`(startIndex, year, month)` from a single read of the `capturedAt` int column in
the grid's exact ordering (`capturedAt DESC, id DESC`), converted to local time
in Dart — the same conversion the displayed label uses. `knownDateAt(index)`
then binary-searches that list and returns a `DateTime` synchronously for every
index in range. The asynchronous `dateAt` lookup, the per-index date cache and
in-flight set, and the view call sites that requested async dates are removed.

**Blocked by:** None — can start immediately.

**Status:** resolved

Base: da3f3047df65342d55986e7663719c0840e3530a

- [x] Dragging the scrubber shows the month in the bubble immediately, with no `…` placeholder, for positions whose page has not loaded
- [x] The floating month heading shows its label immediately on a scrubber jump, before the photos at the target position have loaded
- [x] The date label is correct in the device's local timezone: a photo taken just past midnight local on the first of a new month is labelled as that new month, not the previous one (boundary built in local time, not UTC)
- [x] The date label respects the active availability filter (cloud-only / not-backed-up / all)
- [x] After a sync adds photos and the controller reloads, the date map reflects the current collection
- [x] An empty collection keeps the scrubber and heading out of the way (no spurious date, no crash), as today
- [x] `knownDateAt(index)` returns `null` for indices at or below `-1` and at or above `totalCount`
- [x] The asynchronous `dateAt` method, the per-index `_dates` cache, the `_datesInFlight` set, and the page-load date writes are removed; the mirror's single-row offset date helper is removed if no other caller remains
- [x] Existing gallery controller tests are rewritten to the new synchronous contract and pass; a multi-month local-time boundary test is added
- [x] `flutter analyze` is clean (no new issues in gallery files) and `flutter test` passes in `app/seraph_app/`
- [x] `flutter build web --release --base-href=/app/` succeeds (analyze alone is not a build check)

## Comments

### Implementer report

Done. Committed as `f5c8acb` on `feature/gallery-mode`.

What was built:
- Mirror (`gallery_mirror.dart`): Added `capturedAtColumn({filter})` — covered-index scan returning `List<int>` of epoch-seconds under the same `capturedAt DESC, id DESC` ordering and `_visibilityPredicates` as `queryItems`. Removed `capturedAtAtOffset` (only caller was the controller's `dateAt`, which was deleted).
- Controller (`gallery_grid_controller.dart`): `reload()` now builds `List<_MonthBoundary>` from the column via the same `DateTime.fromMillisecondsSinceEpoch(v * 1000)` local conversion the label uses. `knownDateAt` binary-searches that list and returns `DateTime(year, month)` synchronously (null only for empty/out-of-range). Removed `_dates`, `_datesInFlight`, `dateAt`, and the per-index date writes in `_loadPage`. Revision still bumps once after reload.
- View (`gallery_view.dart`): Dropped the `dateAt` calls in `_DateHeading` (kept the null→`SizedBox.shrink()` guard) and `_jumpTo`.
- Tests (`gallery_grid_controller_test.dart`): Rewrote the 3 date tests to the synchronous contract and added a local-time month-boundary test deriving expected months via the same local conversion (timezone-agnostic).

Decisions the ticket left open:
- `capturedAtAtOffset` had no other callers — removed.
- `_MonthBoundary` is a small top-level class (needed since the controller field references it before its declaration).
- Kept the `date == null ? '…'` fallback in `_ScrubberBubble` — effectively unreachable now for non-empty galleries, but defensive for the pre-reload window.

Gates: `flutter analyze` clean in gallery files (only pre-existing non-gallery infos); `flutter test` 346/346 pass; `flutter build web --release --base-href=/app/` succeeds.

### Verifier verdict — APPROVED

All acceptance criteria verified:

- Instant sync date: View call sites only invoke `knownDateAt` (sync); no `dateAt` remains. Heading returns `SizedBox.shrink()` only when null; bubble shows `…` only as a defensive fallback (scrubber isn't rendered when `totalCount == 0`, and after `open()` the boundary map is populated for non-empty galleries).
- Local time: `_buildMonthBoundaries` uses `DateTime.fromMillisecondsSinceEpoch(column[i] * 1000)` with no `isUtc` — identical to `capturedAtDateTime` in gallery_item_display.dart:134. Same conversion path, no divergence.
- `knownDateAt` contract: Synchronous, binary-searches `_boundaries`, returns `DateTime(year, month)` for valid indices, null for out-of-range/empty. Confirmed at gallery_grid_controller.dart:534.
- Removals: Grep confirms `capturedAtAtOffset`, `.dateAt(`, `_dates`, `_datesInFlight` have no remaining callers; page-load date writes also removed.
- Filter respected: `capturedAtColumn` uses `_visibilityPredicates(...).forFilter(filter)` — same predicate as `queryItems`.
- Empty collection: `_EmptyGallery`/`_EmptyFilterResult` replaces the grid when `totalCount == 0`, so scrubber/heading stay out of the way.
- Tests rewritten: Three date tests now use sync `knownDateAt` (no `await dateAt`); new local-time boundary test derives expected months via the same `DateTime.fromMillisecondsSinceEpoch` conversion (timezone-agnostic), asserting the new-month item lands in the new month. Tests would fail if `knownDateAt` reverted to async/`…`.

Gates:
- `flutter analyze` — only pre-existing non-gallery infos; gallery files clean (one pre-existing `use_super_parameters` in token_refresh_coordination.dart).
- `flutter test test/gallery/gallery_grid_controller_test.dart` — 32 passed.
- `flutter test` — 346 passed.
- `flutter build web --release --base-href=/app/` — Built build/web.
