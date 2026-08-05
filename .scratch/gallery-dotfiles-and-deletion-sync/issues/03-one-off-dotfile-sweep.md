# 03 — One-off sweep tombstones existing dotfile galleryPhotos documents

**What to build:** Dotfile "photos" already sitting in the gallery read model — interrupted-upload
staging files, `.DS_Store`, and the like — are removed by a one-off startup sweep that tombstones
them, so the delta feed delivers removal tombstones to every mirror and clients delete the
Cloud only rows / demote the Synced rows to Device only. The sweep reuses the existing `markDeleted`
/ `withSequence` machinery (which bumps `seq`), so tombstones are produced through the same path as
a live deletion and the delta feed needs no new tombstone source. It runs once as a background
goroutine tracked on the gallery service's existing `wg`/`backfillCtx`, and is gated by a "sweep
done" marker so it does not repeat on every restart. After the sweep, the existing reaper handles
uncovered tombstones under its normal retention window; covered tombstones remain served by the
delta feed until mirrors catch up, exactly as a live deletion would.

**Blocked by:** 01 — Gallery rejects dotfiles on ingest and backfill. The filter must land first so
the sweep does not race with re-ingestion of the very dotfiles it is removing.

**Status:** resolved

- [ ] A one-off startup sweep in the gallery service finds every `galleryPhotos` document whose
      final path segment begins with `.` and runs it through `markDeleted` (setting `deleted:true`
      and bumping `seq` via `withSequence`).
- [ ] The sweep runs as a background goroutine tracked on the existing `wg`/`backfillCtx`,
      mirroring `startRemovalTombstoneSweep` / `resumeIncompleteBackfills`, so startup returns
      promptly.
- [ ] The sweep is gated by a "sweep done" marker stored in an existing collection (or config
      collection) so it does not re-run on subsequent restarts. The exact storage is an
      implementation detail.
- [ ] Pre-existing dotfile documents, after the sweep, are `deleted:true` with a bumped `seq`, and
      a subsequent delta poll delivers their tombstones.
- [ ] Non-dotfile documents are not touched by the sweep.
- [ ] A restart after the sweep has run does not re-run it (the marker is honoured).
- [ ] No new Mongo collection or index is added; no new `migrations/*.json` file is needed (the
      sweep is code-level because it requires `seq` allocation, which a data migration cannot do).
- [ ] The sweep's tombstones behave identically to live deletion tombstones: the gallery's
      `TestDeltaDeliversTombstoneOnDelete` shape confirms a mirror receives and removes them.

## Implementation record

Base SHA: 3137d22bce7c83ba61efe11874c300dce8500b88
Commit: 3df51dd
Implementer report:
- `runDotfileSweep` finds every `galleryPhotos` doc whose final path segment begins with `.` (Mongo regex `/\.[^/]*$`, double-checked against the ticket-01 `isDotfile` predicate), excludes already-deleted ones, and runs each through `markDeleted` — the exact live-deletion path (`deleted:true` + freshly allocated `seq`).
- Files: `gallery/gallery/dotfile_sweep.go` (sweep logic, marker check/set, background launcher mirroring `startRemovalTombstoneSweep`), `gallery/gallery/gallery.go` (one-line wiring in `Start()`), `gallery/gallery/dotfile_sweep_integration_test.go` (two tests).
Decisions the ticket left open:
- Marker storage: a dedicated document `_id: "dotfileSweepDone"` in the existing `gallerySequenceCounters` collection. Marker set only after the sweep completes without error; a partial/interrupted sweep leaves no marker and re-runs on next start (safe because `deleted:{$ne:true}` skips already-tombstoned docs).
- Sweep query: Mongo regex narrowing + Go `isDotfile` guard, excluding `deleted:true` docs to avoid duplicate tombstones on a resumed partial sweep.
Verified: `go build`, `go vet`, `gofmt -l`, and `go test ./...` (Docker-backed) all pass.

Verifier verdict: APPROVED. All acceptance criteria verified against the diff. Sweep reuses `markDeleted`/`withSequence`; runs as a background goroutine on `wg`/`backfillCtx` mirroring existing patterns; gated by `dotfileSweepDone` marker in `gallerySequenceCounters` (set only on full success; partial runs re-run safely via `deleted:{$ne:true}` filter); pre-existing dotfiles tombstoned with bumped seq and delivered by the delta feed; non-dotfiles untouched; restart with a fresh dotfile leaves it alone (marker honoured); no new collection/index/migration; tombstones identical to live deletions. Doc comments match the module's existing heavy doc-comment convention (justified exception to the no-comments rule). Full suite passes (15.277s).
