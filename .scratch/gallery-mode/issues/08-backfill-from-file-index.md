# 08 — Backfill a newly added folder from the File Index

**What to build:** Adding a Gallery Source Folder full of photos that Seraph
already holds fills the gallery with them, not just with photos added from now
on. Adding the folder stays instant and costs no filesystem I/O.

File-change events only fire on change, so a folder of already-indexed photos
would otherwise stay invisible forever. Backfill by issuing the paged prefix
query to the File Index for everything under the folder's resolved
`(providerId, path)`, and feed the results through the same read-model path that
live events use.

**Backfill and live events race by construction** — a folder being backfilled
while photos upload into it will see the same file arrive by both routes — which
is why the read model is upserted rather than inserted. This ticket must
demonstrate that property rather than assume it.

Backfill must not turn a configuration change into a heavyweight server job: it
reads the index, never the File Provider.

**Blocked by:** 04, 07

**Status:** resolved

- [x] Adding a folder containing already-indexed photos makes them appear in the gallery
- [x] The add request returns promptly; backfill proceeds in the background
- [x] Backfill reads the File Index through its published interface and touches no File Provider
- [x] A file arriving by both backfill and a live event produces exactly one gallery item
- [x] Backfill interrupted by a restart resumes or restarts without producing duplicates
- [x] Adding a folder nested inside an already-configured folder does not double its photos in the listing
- [x] Backfill of a large folder does not block the service from serving queries or consuming live events
- [x] Covered at the gallery service's NATS boundary with a stubbed File Index responder, including an explicit test that interleaves backfill pages with live events for the same files

## Comments

Started by one worker that was cut off mid-implementation by a session limit,
leaving a non-compiling tree; finished by a second worker; then one round of
foreman-directed rework after verification.

### Implementer report — `4b0dfd2`

Finished the wiring in `gallery.go`: `backfillLimiter`, `backfillCtx`/
`backfillCancel` with Start/Stop lifecycle joined via the existing `g.wg`, a
`resolveSpace` method, and the `spacesResolveRequest`/`joinPhysicalPath` helpers
`backfill.go` expected. Rather than adding a second copy of Space resolution, the
three existing inline call sites from ticket 07 — `checkAccess`,
`refreshPrefixCache`, `resolveFoldersForUser` — were refactored onto the shared
helpers. `startBackfill` wired into `addSourceFolder` after the prefix-cache
refresh; `resumeIncompleteBackfills` into `Start()`.

The cut-off worker's design was kept as sound, with one gap closed: `runBackfill`
did not check `folder.BackfillDone`, so an idempotent re-ADD or a startup race
would re-walk a completed folder.

**Resolution of the metadata tension.** Backfill reads only `FileIndexListEntry`
fields and never opens the File Provider. Capture Date therefore enters the
fallback chain at rung two — modification time — never EXIF, and
width/height/orientation stay zero. Every such document is flagged
`MetadataPending`, so degraded backfilled photos are visibly distinguishable
rather than silently worse, and the flag is surfaced through
`GalleryListItem.MetadataPending` to the gateway. A live `created`/`changed`
event for the same physical key heals it.

**Consequence worth knowing:** a folder added once and never touched again can
carry `MetadataPending` photos indefinitely. No proactive re-scan exists — that
is ticket 14's territory, correctly out of scope here.

Tests (`backfill_integration_test.go`) use a stubbed File Index NATS responder:
ADD triggers backfill and photos appear in the listing; ADD returns promptly
against an artificially slow stub; the ticket-mandated interleaved
backfill-vs-live-event test; restart mid-backfill; nested folder; and File
Provider never contacted.

### Verifier verdict — APPROVED, with one defect

All acceptance criteria satisfied. `MetadataPending` is genuinely persisted and
genuinely reaches the listing API. ADD is genuinely asynchronous, proven against
a delayed stub rather than incidental speed. Backfill never contacts the File
Provider, proven by running with no provider responder at all. The ticket-07
refactor is behaviour-preserving: same NATS request shape sent fresh per call, no
memoisation introduced, no reverse physical-to-space mapping added.

The verifier judged one defect non-blocking. **The foreman overrode that and sent
it back**, because it defeated the stated design guarantee: `backfillUpsert`'s
`$set` unconditionally overwrote `capturedAt`/`capturedAtSource`/`size`/`mime`
even on documents a live event had already healed, so a resumed or nested-folder
backfill could regress `capturedAtSource` from `exif` to `modTime` while
`metadataPending` stayed `false` — a photo with a wrong capture date and nothing
flagging it. The code's doc comment also cited a test,
`TestBackfillDoesNotDowngradeALiveHealedItem`, that did not exist.

### Rework — `ecb6320`

`backfillUpsert` now places every field in `$setOnInsert`, making backfill
strictly "insert if absent, otherwise leave alone". Backfill can only ever produce
the weakest version of a document, so it has nothing to contribute to a key that
already exists, and healing is one-way by construction rather than by field-by-field
reasoning.

**The fix uncovered a second, larger instance of the same bug:** the unconditional
`$set` also let a stale index page RESURRECT a live-deleted file. `deleted` moved
to `$setOnInsert` too.

Two comments that documented the old downgrade behaviour as intended were
corrected, and the `BackfillDone` guard is now honestly labelled an efficiency
guard — correctness under re-walking belongs to the upsert.

`TestBackfillDoesNotDowngradeALiveHealedItem` now exists for real, with two
sub-tests covering restart-after-healing and nested-folder re-walk. Both fail
against the old code: `capturedAtSource` regressed `exif` → `modTime` and
`capturedAt` regressed from a 2007 EXIF date to a 2024 modification time. The
modification time was deliberately chosen far later than the EXIF date so a
regression moves the photo visibly rather than subtly.

Gallery suite 36/36; `api-gateway` all packages pass on a clean uncached `-p 1` run.
