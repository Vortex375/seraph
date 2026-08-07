# Gallery Scrubber Instant Date

Status: ready-for-agent

Vocabulary: [CONTEXT.md](../../CONTEXT.md)
Architecture decisions: [ADR 0001](../../docs/adr/0001-gallery-read-model-and-device-mirror.md)

## Problem Statement

Gallery Mode's date scrubber — the draggable vertical slider that jumps through
the photo collection — shows the month the user is dragging over in a small
bubble beside the handle. Today that bubble shows a placeholder (`…`) until the
date for the current position is known, and the date only becomes known once an
asynchronous lookup resolves.

The asynchronous lookup is *not* waiting on the network or on image bytes. It is
a single-row SQLite read against the local mirror (`LIMIT 1 OFFSET N` over the
gallery's `capturedAt DESC, id DESC` ordering). On a large collection, dragging
the thumb fast queues many of these offset scans on a single serialized SQLite
connection, and the bubble stays on `…` until either the queue drains or the
page-load path (which also primes the date cache) reaches that index. In
practice the date appears roughly when the first photo of the page it lives on
finishes loading — exactly the lag the user sees.

This makes quick navigation difficult. The user is dragging through a known,
fully-indexed local database and the slider's own length is derived from a
`COUNT(*)` over that same database, yet the date label lags behind the thumb as
if it were waiting on something remote.

## Solution

Replace the asynchronous, per-index date lookup with a one-time, synchronous
date map built from the local mirror at the same moment the slider's total
length is already computed.

When the gallery opens (or reloads after a sync or filter change), alongside
the existing `COUNT(*)` that fixes the slider's length, the controller runs a
single query that reads only the `capturedAt` column of every visible Gallery
Item, in the exact ordering the grid uses (`capturedAt DESC, id DESC`). It then
walks that column once in Dart, converting each epoch-seconds value to a local
`DateTime` — the same conversion the displayed label uses — and records a
boundary entry `(startIndex, year, month)` whenever the (year, month) changes.
The full column is then discarded; only the boundary list (a few hundred
entries for a multi-year collection) is held.

`knownDateAt(index)` becomes an O(log n) binary search over the boundary list,
returning a `DateTime` for that month instantly and synchronously. The `…`
placeholder disappears for both the scrubber bubble and the floating month
heading, for every position the thumb can reach, with no async work and no
page load required.

## User Stories

1. As a gallery user, I want the date label beside the scrubber handle to appear
   the instant I start dragging, so that I never see a `…` placeholder while
   the position is being resolved.
2. As a gallery user, I want the date label to update continuously and
   immediately as I drag the scrubber, so that I can skim to the month I'm
   looking for without waiting on lookups.
3. As a gallery user, I want the floating month heading at the top of the grid
   to show its label instantly when I jump to a new position via the scrubber,
   not only once the photos there have loaded, so that the heading and the
   scrubber bubble never disagree.
4. As a gallery user, I want the date label to be correct in my local timezone,
   so that a photo taken just past midnight on January 1st is labelled "January"
   and not "December".
5. As a gallery user, I want the date label to remain stable and correct after
   a sync adds new photos, so that dragging after a reload reflects the current
   collection.
6. As a gallery user, I want the date label to respect the active availability
   filter, so that a cloud-only or not-backed-up view shows dates from the
   filtered set, not the whole collection.
7. As a gallery user with a very large collection, I want the scrubber to stay
   responsive, so that building the date map does not stall opening the gallery
   or inflate memory.
8. As a gallery user with an empty collection, I want the scrubber and heading
   to stay out of the way (no spurious date, no crash), as they do today.
9. As a gallery user, I want the date label to agree with the month that would
   be shown for the photo at that index, so that the scrubber, the heading and
   the grid never contradict each other.

## Implementation Decisions

- **Where the date map is built.** The map is built inside `GalleryGridController`
  during `reload()` (and therefore `open()`), immediately after the existing
  `totalCount` query that already fixes the slider's length. It shares the same
  lifecycle: it is rebuilt on every reload, so filter changes, syncs and
  tombstones are reflected exactly as `totalCount` already is.

- **The boundary record.** The controller holds a list of month boundaries
  produced from the column read. Each boundary records the zero-based
  `startIndex` at which a given `(year, month)` first begins, plus the `year`
  and `month`. An empty collection yields an empty boundary list. A
  single-month collection yields a single boundary at index 0.

- **Why the column is read in full and reduced in Dart, not via SQL
  `GROUP BY`.** The displayed label converts `capturedAt` (epoch seconds) to a
  *local* `DateTime`. Grouping in SQLite with `strftime(..., 'unixepoch')` would
  group in UTC, which can disagree with the local-time label by a month around
  midnight and is fragile under DST. Reading the int column once and converting
  in Dart uses the identical code path as the label, so the boundary map and the
  label can never disagree. The read is a covered scan on the existing
  `idx_gallery_items_captured_at_id` index (the column is in the index, so no
  table access is needed) and transfers only one int per item — a one-shot,
  single-digit-millisecond cost on mobile, paid once per reload.

- **`knownDateAt` becomes synchronous and authoritative.** It binary-searches
  the boundary list for the largest `startIndex <= index` and returns a
  `DateTime` for that `(year, month)`. It returns `null` only when the boundary
  list is empty (collection not yet loaded / empty). It no longer depends on
  whether a page has been loaded.

- **The asynchronous date path is removed.** The `dateAt(index)` method, the
  `_dates` per-index cache, the `_datesInFlight` set, and the mirror's
  `capturedAtAtOffset` single-row helper (if no other caller uses it) are
  removed. The scrubber's `_jumpTo` no longer calls `dateAt`; the floating
  heading's "ask and stay out of the way" path no longer calls `dateAt`. The
  page-load path (`_loadPage`) no longer writes a per-index date cache; it
  continues to populate the item cache exactly as today.

- **Mirror query added.** A new mirror method reads the `capturedAt` int column
  over the same ordering and visibility predicate as `queryItems`, returning
  `List<int>`. It reuses the existing ordering (`capturedAt DESC, id DESC`) and
  filter predicate construction, so the column order is identical to what the
  grid paginates over.

- **Revision / rebuild semantics.** The scrubber bubble and heading continue to
  read `knownDateAt` and rebuild on `controller.revision`. The revision is
  bumped after the boundary map is built (as it already is after reload), so the
  widgets flip from not-built to built in one rebuild. No per-async-lookup
  revision bumps remain.

- **Timezone correctness is the defining property.** The boundary construction
  and the label rendering must use the same local-time conversion. Any future
  change to how labels render months must keep the boundary construction in
  lockstep.

## Testing Decisions

- **Seam.** The existing mirror-seam tests in `gallery_grid_controller_test.dart`
  drive `GalleryGridController` against a pre-populated in-memory `GalleryMirror`
  (Drift over `NativeDatabase.memory()`). This is the highest seam that decides
  what the scrubber and heading show, and it requires no widgets and no network.
  No new seam is introduced.

- **What makes a good test here.** Tests assert on the *external behaviour* of
  the controller — what `knownDateAt` returns for given mirror contents — never
  on the internal boundary representation or on SQLite query text. They are the
  kind of test that would still pass if the boundary map were rebuilt a
  different way, and would fail if the date were wrong or the placeholder
  returned.

- **Prior art.** The existing tests `the scrubber can ask for a date without
  loading that page`, `dates from a loaded page match the mirror order`, and
  `a date beyond the end of the gallery is null` are the direct antecedents and
  will be rewritten to the new synchronous contract:
  the first asserts `knownDateAt` returns a non-null date for an unloaded index
  immediately after `open()`; the second continues to assert dates match the
  mirror order; the third asserts `knownDateAt` returns `null` for indices at
  or below `-1` and at or above `totalCount`.

- **New behaviour to cover at the seam.** A multi-month fixture (items spanning
  a month boundary, including one just past midnight local on the first of a
  new month) is added so the local-time grouping is exercised: `knownDateAt`
  for the index at midnight returns the *new* month, confirming the boundary is
  built in local time rather than UTC. An empty-collection case is covered by
  the existing "empty gallery" test.

- **Verification gates.** `flutter analyze` and `flutter test` in
  `app/seraph_app/`, and the web release build `flutter build web --release
  --base-href=/app/` (per AGENTS.md, analyze alone is not a build check). The
  gallery controller tests must pass with the rewritten date assertions.

## Out of Scope

- Changing the label format (still `galleryMonthLabel`, e.g. "March 2022").
- Changing the scrubber's visual design, handle, or drag physics.
- Caching the boundary map across reloads or persisting it to the database.
- Showing a finer-than-month granularity (day or year) in the bubble.
- Any change to how `totalCount` or pagination works.
- Pre-warming or changing the thumbnail/image loading pipeline.

## Further Notes

- The one-time column read scales linearly with item count for *transfer* cost
  but the held memory is O(months), not O(items). For collections into the
  hundreds of thousands the read is still a covered index scan and remains
  cheap; if collections ever reach the millions, a sampling/interpolation
  variant would be worth revisiting (not needed for the galleries this app
  targets).
- `capturedAt` is epoch *seconds*; the existing conversion multiplies by 1000
  for milliseconds. The boundary construction must use the same conversion.
- If `capturedAtAtOffset` on the mirror turns out to have other callers, it is
  kept; otherwise it is removed to avoid leaving a now-unused offset-scan path
  whose whole purpose was the scrubber's async lookup.
