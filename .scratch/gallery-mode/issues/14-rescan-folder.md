# 14 — Rescan folder

**What to build:** A user who knows Seraph's index is behind reality — photos
copied in over SMB that never showed up, say — can force a real re-scan of a
Gallery Source Folder themselves, without needing an administrator.

Backfill reads the File Index, which is fast and cheap but inherits whatever
staleness the index has. Index staleness is a pre-existing property of Seraph;
Gallery Mode neither fixes it nor pretends it away, so it offers an explicit way
out. This action triggers a genuine File Provider re-scan, unlike adding a
folder.

**Blocked by:** 08

**Status:** resolved

- [x] A "Rescan folder" action is available per Gallery Source Folder in the app
- [x] Triggering it causes a real File Provider re-scan of that folder, not just a re-read of the index
- [x] Photos present on disk but missing from the index appear in the gallery afterwards
- [x] The user gets feedback that a rescan is running and that it has finished
- [x] Rescanning a folder that is already up to date changes nothing and produces no duplicates
- [x] Triggering a rescan twice in quick succession does not run two scans over the same folder
- [x] A rescan of a large folder does not block gallery queries
- [x] Covered at the gallery service's NATS boundary

## Comments

### Implementer report

The first agent on this ticket was cut off by a session limit before running any
test, and left `dcc209b` marked explicitly as an unverified draft. This report
covers the second pass, which treated that draft as work to verify rather than
as done, and landed `f69b314`.

**Changed** — `gallery/gallery/rescan.go` and `rescan_integration_test.go` only;
the draft's other files proved correct as committed.

- **Tombstone resurrection bug fixed.** `healPendingMetadata` selected on
  `metadataPending` alone, but `markDeleted` leaves that flag set — so a deleted
  backfill placeholder was fed to `upsertPhoto`, which writes `deleted:false`
  and brings it back. This is the same defect ticket 08 fixed in
  `backfillUpsert`, reached through a second door. The heal pass now excludes
  tombstones. New test; without the fix it fails (deleted→false, seq 1→2, item
  reappears in LIST).
- **`TestRescanTwiceInQuickSuccessionRunsOneScan` was vacuous** — it passed with
  the concurrency guard deleted. Rewritten to count walks by directory
  `FileInfoEvent`s; it now fails at 400 vs 200 without the guard.
- **`TestRescanHealsMetadataPendingPhotos` tested the wrong thing** — it healed
  via the walk, not via the heal pass. It now primes the indexer baseline first,
  and fails if the heal pass is removed.
- Documented that `Readdir(-1)` is load-bearing: only a full listing carries the
  marker file-indexer needs to reconcile deletions.

**Criterion 2 — genuine re-scan, established by tracing the real chain.**
`walkRescan` drives `Readdir(-1)` through the File Provider client;
`handleReaddir` publishes a `FileInfoEvent` per entry onto the `SERAPH_FILE_INFO`
JetStream stream that file-indexer durably consumes (`consumer.go:95`), which
republishes `FileChangedEvent` for anything new. Tests run a real
`FileProviderServer`; only the indexer is stubbed, mirroring its documented
new/changed rule. The path never touches the File Index.

### Decision — rescan heals MetadataPending (question deferred here by ticket 08)

**Yes, it heals.** The walk provably cannot do it: file-indexer publishes nothing
for a file whose bytes are untouched, which is exactly a backfilled photo's
state. Confirmed empirically — disabling the heal pass while leaving the walk
running makes the test fail.

Without it, a folder added once carries photos sorted by modification time rather
than true Capture Date forever, with no user remedy. Rescan is the right home for
the fix: it is the explicit "make this folder match reality" action, it is already
backgrounded and rate-limited, it is already paying the File Provider cost, and it
reuses `upsertPhoto`/`withSequence` so app mirrors receive the corrections.

### Verifier verdict — APPROVED

Reviewed independently against `git diff e173019..f69b314`, verifying the whole
feature rather than the delta between the two commits, since the draft commit was
explicitly untrusted.

All eight acceptance criteria met:

1. Per-folder rescan action in `gallery_view.dart`.
2. **Genuine File Provider re-scan**, confirmed by independently tracing
   `walkRescan` → `fileprovider.Client.OpenFile/Readdir` → server publishes
   `FileInfoEvent` → file-indexer `handleReaddir`/`upsertFile` → publishes
   `FileChangedEvent` for new/changed → gallery's existing `ingest.go` consumer
   upserts. It never touches `galleryPhotos` directly except via the metadata-heal
   pass, which is filtered to exclude tombstones.
3. `TestRescanFindsPhotosMissingFromIndex`.
4. `rescanRunning` field + app polling + snackbar messages.
5. `TestRescanOfUpToDateFolderChangesNothing`.
6. Atomic `markRescanRunning` + the meaningfully rewritten
   `TestRescanTwiceInQuickSuccessionRunsOneScan`.
7. `TestRescanDoesNotBlockGalleryQueries`.
8. `rescan_integration_test.go`, at the gallery service's NATS boundary.

Standing regression invariants all intact; `resolveFoldersForUser` and
`backfillUpsert` were not touched by this diff at all. The new
`healPendingMetadata` explicitly guards tombstone resurrection and has its own
test for it.

**Checks:** gallery suite 64/64 (five consecutive clean runs;
`TestDeltaConcurrentWritersLoseNothing` passed every time), api-gateway `-p 1` all
packages ok, `go vet` clean on both modules, `flutter analyze` 0 errors,
`flutter test` 66/66, `flutter build web --release --base-href=/app/` succeeds.

### Noted, not fixed

- Rescan feedback is poll-based (LIST + `RescanRunning`) and binary
  running/finished — no progress reporting.
- `healPendingMetadata` uses unpaged `cur.All`; deliberate, to avoid a cursor
  timeout during slow per-file I/O, but memory is linear in the pending count.
- `resolveFolderPrefix` (ticket 08 code) logs "skipping its backfill" even when
  called from rescan — cosmetic.
- No Flutter widget test for the Rescan action; no gallery widget tests exist and
  the ticket's coverage criterion is the Go NATS boundary.
- The gallery suite binds a hardcoded NATS port 4222, so two concurrent runs on
  one machine collide and fail for reasons unrelated to the code. Spun off as a
  separate task.
