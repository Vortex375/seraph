# 01 — Gallery rejects dotfiles on ingest and backfill

**What to build:** Gallery Mode stops indexing any file whose final path segment begins with `.`
(a dotfile). Both the live `FileChangedEvent` consumer and the backfill paged-prefix query skip
such entries, so no new dotfile — an interrupted-upload staging file, a `.DS_Store`, an editor lock
file — ever produces a `galleryPhotos` document. Existing dotfile documents already in the read
model are left in place for the one-off sweep (ticket 03) to tombstone; this ticket only stops new
ones from entering.

**Blocked by:** None — can start immediately.

**Status:** resolved

- [ ] A shared "is a dotfile" predicate (final path segment begins with `.`) is applied in the
      gallery service's live ingest path, immediately after the existing `IsDir` reject and before
      the prefix-cache lookup, so both the `Deleted` and `Created`/`Changed` branches are covered.
- [ ] The same predicate is applied in the backfill result loop, alongside the existing `IsDir`
      skip, so dotfile entries returned by a File Index paged prefix query are not upserted.
- [ ] A `Created` or `Changed` event for a dotfile path under a configured Gallery Source Folder
      produces no `galleryPhotos` document.
- [ ] A `Deleted` event for a dotfile path produces no document (the filter rejects it before
      `markDeleted`), confirming the filter covers the delete branch too.
- [ ] A backfill page containing a dotfile entry produces no `galleryPhotos` document for it.
- [ ] Non-dotfile files under the same folders continue to ingest and backfill exactly as before.
- [ ] The File Provider and File Index are not changed — the filter is gallery-only.

## Implementation record

Base SHA: 409e1f952c1be53a5db4c2c0c7ae45aa663c84cb
Commit: bbf29ea
Implementer report:
- Added `isDotfile(filePath string) bool` in `gallery/gallery/ingest.go` — `strings.HasPrefix(path.Base(filePath), ".")`.
- Wired into `handleMessage` after the `IsDir` reject and before the prefix-cache lookup (both `Deleted` and `Created`/`Changed` branches covered).
- Wired into `backfill.go` `runBackfill` alongside the existing `IsDir` skip.
- Tests: `TestDotfileEventsProduceNoPhoto` (live), `TestBackfillSkipsDotfileEntries` (backfill).
- Verified: `go build`, `go vet`, `gofmt -l` clean; full gallery suite (Docker via rancher socket) passes.
Decisions the ticket did not settle:
- Helper placed in `ingest.go` (same package as `backfill.go`), not a new file.
- `path.Base("")` returns `"."` so an empty path is treated as a dotfile — harmless/arguably correct.

Verifier verdict: APPROVED. All acceptance criteria verified against the diff; predicate, placement, branch coverage, and tests all confirmed. Test suite passes (16.048s). File Provider and file-indexer untouched. Note: doc comments on `isDotfile` and the two test functions match the module's existing heavy doc-comment convention; counted as idiomatic, not a defect.
