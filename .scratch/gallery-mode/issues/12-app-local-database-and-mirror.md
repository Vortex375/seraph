# 12 — App local database and mirror from the delta feed

**What to build:** The app keeps a local mirror of the user's gallery, synced
through the delta feed, so browsing is a local indexed query rather than a
network round trip per screen. This is the app's **first local database** and
its first schema-migration story, and both need to be set up properly here
because everything after this ticket depends on them.

**Sync state, the mirror and the UI list are one table, not three.** Cloud items
arrive through the delta feed; device items will later be imported from the
media store into the same table; dedup happens at write time. That is what makes
the merged view a single indexed query ordered by Capture Date.

The alternative — a lazy two-cursor merge over the device and the server — was
rejected and must not be reintroduced: item counts would be unknown, so no date
scrubber and no honest scrollbar; dedup after paging makes pages collapse and
the layout shift mid-scroll; and every scroll would need the network.

No UI in this ticket. It is verifiable by driving the mirror and inspecting what
it returns.

**Blocked by:** 10

**Status:** resolved

- [x] The app has a local database with a migration mechanism that survives an app upgrade adding a column
- [x] A cold start with no local data populates the mirror from the delta feed
- [x] A subsequent sync applies only changes since the last seen sequence
- [x] A tombstone removes the item from the mirror
- [x] The sync cursor survives an app restart, so a restart does not re-fetch the whole gallery
- [x] A sync interrupted mid-page resumes without losing or duplicating items
- [x] The mirror can be queried in Capture Date order, paged, and reports a total count
- [x] Querying the mirror works with no network available
- [x] Covered at the app's mirror seam: a stubbed HTTP backend feeds the delta feed, assertions read the mirror's query results — following the existing chat service tests' approach to stubbing HTTP

## Comments

### Implementer report

The implementing agent's own report was lost when its session ended; what
follows is reconstructed from the two commits it left, `46e8f6e` and `e173019`.

The app's first local database: a drift/sqlite3 mirror of the gallery with a
real schema-migration mechanism (`schemaVersion` + `MigrationStrategy`).

- Sync state, the mirror and the future UI list are **one table**
  (`GalleryItems`), per the ticket's binding constraint — device items
  (ticket 15) will dedup into the same rows rather than merging two sources at
  read time. A small separate `SyncCursors` table holds only watermark and
  pending-cursor bookkeeping; it is not a second data table.
- `GallerySyncService` polls `GET /api/gallery/delta`; `GalleryMirror` applies
  pages transactionally — upserts keyed on `(providerId, path)`, tombstone
  deletes, and cursor bookkeeping (`since`/`pendingCursor`) so a restart resumes
  instead of re-fetching and a mid-poll interruption neither duplicates nor
  loses items.
- Tests stub Dio at the HTTP boundary, following `ChatService`'s tests, and drive
  `GalleryMirror`/`GallerySyncService` directly, asserting on local query results
  with no network involved.

**Web build fix (`e173019`).** The first cut used drift's `NativeDatabase`
unconditionally, so the shipped web build failed to compile — sqlite3's FFI
implementation pulls in `dart:ffi`, which is unavailable on web, and the
Dockerfile builds and serves `flutter build web --release`. A conditional-import
seam under `mirror/connection/` now selects `NativeDatabase` natively and
`WasmDatabase` on web, with `sqlite3.wasm` and `drift_worker.js` served from
`web/`.

### Verifier verdict — APPROVED

Verified independently in an isolated worktree against `git diff 2fc8a31..e173019`,
with the tree checked out at `e173019` so ticket 14's later WIP commit could not
influence the result.

- **All checks pass:** `flutter analyze` clean, full test suite green (66 tests,
  16 of them gallery-specific), `flutter build web --release --base-href=/app/`
  succeeds.
- **Codegen is self-consistent:** re-running `build_runner` regenerated identical
  output, confirming the committed `.g.dart` matches the schema source. No stray
  changes.
- **One table, not three:** a single `GalleryItems` table serves as mirror, UI
  source and dedup target. The rejected lazy two-cursor merge over device and
  server is absent in every form.
- **Migration story is real:** an incremental `MigrationStrategy` with `onUpgrade`,
  demonstrated by a genuine v1→v2 test against a hand-built legacy SQLite file —
  not merely a version constant.
- **Tombstone deletion, resumability** (mid-page cursor persisted *before*
  advancing `since`), capture-date-ordered paged query with total count, and HTTP
  stubbed at the Dio interceptor exactly as the chat service tests do.
- The `e173019` fix correctly swaps `sqlite3_flutter_libs` — native-only, would
  break the wasm/web compile — for plain `sqlite3` behind the conditional-import
  connection seam.
