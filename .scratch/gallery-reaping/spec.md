# Gallery read-model reaping

Status: ready-for-agent

Related: gallery-mode (`.scratch/gallery-mode/`) — tickets 06 (gallery service and source
folders), 07 (read-model capture date and listing), 10 (delta feed with tombstones), 14 (rescan
folder); ADR 0001 (gallery read model and device mirror); migration `000004`
(`galleryPendingTombstones` 30-day TTL).

## Problem Statement

When a user removes a Gallery Source Folder, the gallery service records per-user removal
tombstones in `galleryPendingTombstones` (expired after 30 days by migration `000004`) but leaves
the underlying `galleryPhotos` documents untouched. This is correct for the common case — the same
physical file may still be visible to other users, or to the same user through another folder, so
the shared read-model document must not be removed.

But when the removed folder was the *last* Gallery Source Folder covering a physical path, the
underlying `galleryPhotos` document becomes orphaned: not visible to any user (no folder resolves to
its physical prefix), and never reaped. It accumulates in the database indefinitely. The same applies
to `galleryPhotos` documents flagged `deleted:true` (file physically removed from disk) once no folder
covers them: the soft-delete tombstone they provide to the delta feed is only ever served through a
covering folder's translation, so an uncovered `deleted:true` document serves no one yet is never
removed.

Over time, as folders are added and removed and files are deleted from disk, these orphaned documents
accumulate without bound, growing the `galleryPhotos` collection and degrading its indexes for no
benefit — the information they carry is reachable by no user.

The gallery service already maintains the global view needed to detect this: the `prefixCache` is
rebuilt across *all* users' folders (not per-user — see `ingest.go`'s `refreshPrefixCache`).
However, REMOVE deliberately does not refresh the prefix cache (preserving ticket 06's tested
"REMOVE touches nothing else" contract), and no code path computes "physical paths no longer covered
by any folder" or reaps the documents beneath them. There is no remaining gallery-mode ticket that
addresses this gap.

## Solution

When a Gallery Source Folder is removed, the gallery service determines which `galleryPhotos`
documents are no longer covered by *any* user's current Gallery Source Folder set, and reaps them
after a retention guard so delta-feed tombstone delivery windows are not cut short and a grace period
for re-adding the folder is preserved. The read model stops growing without bound, while every
guarantee the delta feed and access-control model rely on is preserved: a reaped document is, by
construction, one no user could see and no mirror could still be delivered through the
`galleryPhotos` tombstone source (the independent `galleryPendingTombstones` outbox carries
folder-removal tombstones, with its own 30-day TTL).

The reaper is triggered by REMOVE *and* a periodic background sweep. REMOVE marks newly-uncovered
documents immediately so coverage is current the moment a folder goes away; the periodic sweep reaps
documents whose retention window has elapsed, so infrequent REMOVEs do not leave orphans sitting
indefinitely. No File Provider contact occurs on either path. REMOVE's "touches no File Provider"
contract is preserved; its "touches nothing but the configuration document" contract is intentionally
narrowed to "touches no File Provider and no other service."

## User Stories

1. As a gallery user, when I remove the last Gallery Source Folder covering a set of photos, I want
   the gallery service to stop holding onto those photos' read-model rows, so that the database does
   not grow without bound as I reorganise my folders over time.
2. As a gallery user, when I remove a folder that another user also has configured as a Gallery Source
   Folder, I want the shared photos to remain visible to that other user, so that removing my folder
   never affects anyone else's gallery.
3. As a gallery user, when I remove a folder but I still have another folder covering the same physical
   files, I want those photos to remain in my gallery, so that overlapping folders behave as I expect.
4. As a gallery operator, when a file is physically deleted from disk and no folder covers its path
   anymore, I want the stale `deleted:true` read-model row to eventually be removed, so that soft-delete
   rows do not accumulate forever for paths no one can see.
5. As a gallery operator, when a `deleted:true` row is still covered by some user's folder, I want it
   to be retained, so that the delta feed can still deliver the deletion tombstone to that user's
   mirror.
6. As a gallery mirror, when a folder is removed and my owner's tombstone is delivered through
   `galleryPendingTombstones`, I want that tombstone to arrive even after the underlying
   `galleryPhotos` row has been reaped, so that reaping the read model never causes a mirror to miss a
   removal.
7. As a gallery user, when I remove a folder and then re-add it (or an overlapping one) within the
   retention window, I want the previously-orphaned photos to reappear without needing a full re-index,
   so that brief folder reorganisation is cheap.
8. As a gallery operator, I want REMOVE to keep its "no File Provider contact" guarantee, so that
   removing a folder is never turns into an expensive operation that walks or contacts the File
   Provider.
9. As a gallery operator, I want the reaper to be triggered by REMOVE (for immediate marking) and by a
   periodic background sweep (for time-expired reaping), and to perform only local Mongo operations,
   so that infrequent REMOVEs do not leave orphans sitting indefinitely and there is no new
   cross-service dependency.
10. As a gallery developer, I want the global prefix coverage computation to reuse the existing
    `prefixCache`/`refreshPrefixCache` machinery, so that there is one source of truth for "which
    physical paths are covered by any folder".
11. As a gallery developer, I want reaping to allocate no delta sequence and emit no delta event for
    reaped uncovered documents, so that the delta feed is unaffected (the documents were already
    invisible and the removing user's tombstone is carried by the independent outbox).
12. As a gallery developer, I want the `TestRemoveTouchesNoFileProvider` contract updated to
    "REMOVE touches no File Provider and no other service" rather than "touches nothing but the config
    document", so that the intentionally-narrowed contract is correctly documented and tested.
13. As a gallery operator, I want a retention guard between a document becoming uncovered and being
    reaped, so that no in-flight tombstone delivery window is cut short and a grace period for
    re-adding a folder is preserved.
14. As a gallery developer, I want the retention guard to use the same `DeltaTombstoneRetention`
    window already governing `galleryPendingTombstones`, so that reaping and tombstone expiry are
    consistent and there is one retention constant to reason about.

## Implementation Decisions

- **New reaping module in the `gallery` service.** A reaper is invoked from `removeSourceFolder`
  after `startRemovalTombstoneSweep` records the removing user's per-user tombstones. It runs in the
  background (goroutine, tracked by the existing `wg`/`backfillCtx`, mirroring `startRemovalTombstoneSweep`
  and `startSeqBump`) so the REMOVE request/reply returns promptly.

- **REMOVE now refreshes the prefix cache.** The "REMOVE deliberately does not refresh the prefix
  cache" choice in `gallery.go` (`removeSourceFolder`) is reversed: REMOVE calls `refreshPrefixCache`
  before computing coverage, so the global prefix set reflects the just-removed folder's absence. This
  intentionally narrows the tested contract from "REMOVE touches nothing but the configuration
  document" to "REMOVE touches no File Provider and no other service." `TestRemoveTouchesNoFileProvider`
  is updated to assert the narrower contract (no NATS request to any other service; local Mongo
  writes are permitted).

- **Coverage computation reuses the global prefix set.** The reaper derives the set of physical
  prefixes covered by *all* users' current Gallery Source Folders from the same `prefixCache` that
  ingestion uses (rebuilt by `refreshPrefixCache`). A `galleryPhotos` document is *uncovered* when its
  `(providerId, path)` is not contained by any prefix in that set. The `prefix.contains` /
  `prefixFilter` helpers already in the package are reused, not duplicated.

- **Retention guard via an `uncoveredAt` watermark.** A new `uncoveredAt` field is added to
  `galleryPhotos` (migration `000005`). Two paths act on it:
  - **REMOVE (immediate mark + opportunistic reap).** On each REMOVE, after `refreshPrefixCache`
    updates the global prefix set, the reaper marks every document now uncovered and not already
    marked with `uncoveredAt = now` (a bulk `$set` filtered by "not covered by any current prefix AND
    `uncoveredAt` absent"), then opportunistically deletes documents where `uncoveredAt < now -
    DeltaTombstoneRetention` so a burst of folder reorganisation is cleaned up promptly.
  - **Periodic sweep (time-expired reap).** A background goroutine, started by `Start` and cancelled
    by `Stop` (tracked on the existing `wg`/`backfillCtx`, mirroring the ingest/spaces-changed
    consumers), ticks on a fixed interval and deletes documents where `uncoveredAt < now -
    DeltaTombstoneRetention`. It does not re-derive coverage — it only reaps marks that have aged past
    the retention window, so its cost is independent of folder count. The tick interval is short
    relative to `DeltaTombstoneRetention` (the exact value is a config default, not a per-deployment
    knob in this ticket) so the lag between eligibility and reaping is bounded and small.
  A document becomes eligible for reaping no sooner than `DeltaTombstoneRetention` (30 days) after it
  first became uncovered. The periodic sweep guarantees that eligibility is honoured even when no
  further REMOVE ever happens, closing the residual gap a REMOVE-only trigger would leave.

- **Reaped set includes `deleted:true` uncovered documents.** Both `deleted:false` and `deleted:true`
  documents are reaped once uncovered and past the retention guard. An uncovered `deleted:true`
  document serves no delta-feed consumer (its tombstone is only served through `translate()`, which
  requires a covering folder), so reaping it is observably a no-op for the feed. Covered `deleted:true`
  documents are never reaped — they still serve the delta feed for the covering user(s).

- **No delta sequence allocation, no delta event.** Reaping emits no `FileChangedEvent`, bumps no
  `seq`, and writes no `galleryPendingTombstones` row. The removing user's tombstone was already
  recorded by `recordRemovalTombstones` (independent of `galleryPhotos`); other users either still
  cover the document (so it is not reaped) or never covered it (so they have no tombstone owed). The
  delta feed's two tombstone sources are unaffected: `galleryPendingTombstones` is precomputed and
  independent; the `galleryPhotos.deleted:true` source only serves covered documents.

- **Un-marking on re-add (explicit ADD `$unset`).** A folder re-added within the retention window
  must clear `uncoveredAt` on the documents it now covers, so remove-then-re-add is cheap. This is
  **not** a side effect of backfill: `backfillUpsert` uses `$setOnInsert` for every field and writes
  nothing to an already-present document, so it would leave `uncoveredAt` set on a
  marked-but-not-reaped document. ADD therefore runs an explicit `$unset` of `uncoveredAt` over the
  re-added folder's prefix (a bulk update mirroring the mark's bulk `$set`), in the same background
  hand-off that starts backfill. This is one of three un-marking paths; the others are RESCAN re-cover
  (below) and the coverage recheck the next REMOVE's mark pass performs (which sets `uncoveredAt` only
  on documents not covered by any current prefix, so a re-covered document is naturally left alone by
  the mark — but the explicit `$unset` is still required to clear a stale mark from a prior REMOVE).

- **Grace-period benefit is documented.** Because reaping is deferred by the retention window, a user
  who removes a folder and re-adds it (or an overlapping one) within 30 days finds the
  previously-orphaned `galleryPhotos` documents still present (`deleted:false`, still indexed) — they
  become visible again without a re-backfill. After the retention window, reaped documents are
  re-discovered by backfill if a folder is re-added (the File Index still holds them), so there is no
  data loss, only a re-backfill cost.

- **No new Mongo collections.** One new field (`uncoveredAt`) on `galleryPhotos` and one new
  migration (`000005`). A TTL-style index is *not* used for reaping (reaping is driven by REMOVE, not
  by Mongo's TTL monitor), but an index on `uncoveredAt` supports the mark/delete queries efficiently.

- **Interaction with RESCAN (ticket 14).** `healPendingMetadata` excludes `deleted:true` documents
  and is unaffected. RESCAN walks the File Provider tree and causes the file-indexer to catch up; it
  does not touch `uncoveredAt`. A rescan of a folder whose documents are marked `uncoveredAt` but not
  yet reaped clears `uncoveredAt` on any document the walk re-covers (a `$unset` on
  `uncoveredAt`), so a re-add-then-rescan sequence does not leave stale marks. This is part of the
  reaper's contract, not a separate ticket.

## Testing Decisions

- **Single seam: the gallery service's existing NATS + MongoDB integration-test boundary**
  (testcontainers + embedded NATS), as used by `backfill_integration_test.go`,
  `delta_integration_test.go`, `rescan_integration_test.go`. The reaper is driven by issuing a REMOVE
  over `GallerySourceFolderCrudTopic` and asserting on the `galleryPhotos` / `galleryPendingTombstones`
  collections directly. No new seam is introduced.

- **What makes a good test here.** Tests assert external behaviour (which documents survive, what the
  delta feed delivers) and never the reaper's internal goroutine structure. The mark-and-delete
  mechanic is observed through the collection state, not mocked.

- **Prior art / tests to extend.**
  - `TestRemoveTouchesNoFileProvider` — must be relaxed to "no File Provider / no other service"
    (local Mongo writes permitted) and kept asserting no NATS request leaves the gallery service.
  - `delta_integration_test.go` tombstone tests (`TestDeltaDeliversTombstoneOnDelete`,
    `TestDeltaDeliversFolderRemovalTombstone`) — extended to assert the tombstone still arrives after
    the underlying `galleryPhotos` row is reaped.
  - `backfill_integration_test.go` interleaving tests — pattern reused for "REMOVE + concurrent live
    event on a still-covered document" non-interference.

- **Required test cases.**
  1. REMOVE of the *last* folder covering a physical path → the `galleryPhotos` documents under it are
     marked `uncoveredAt`, and reaped once the retention window elapses (time advanced in-test).
  2. REMOVE when another user's folder still covers the same physical path → documents are NOT marked
     `uncoveredAt`, NOT reaped, remain `deleted:false`.
  3. REMOVE when the same user has another folder covering the same physical path → NOT marked, NOT
     reaped.
   4. REMOVE, then re-add a covering folder within the retention window → documents still present,
      `uncoveredAt` cleared by the explicit ADD `$unset` (not by backfill, which is `$setOnInsert`
      only), visible again without re-backfill.
  5. REMOVE, advance past retention, reap, then poll the delta feed → the removing user still receives
     the folder-removal tombstone from `galleryPendingTombstones` (independent of the reaped row).
  6. `deleted:true` uncovered document, past retention → reaped.
  7. `deleted:true` covered document → NOT reaped, retained for delta-feed tombstone delivery.
  8. Reaped uncovered document produces no delta event and allocates no sequence (assert no new row in
     `galleryPendingTombstones` and no `seq` bump attributable to the reap).
  9. REMOVE issues no NATS request to any other service (the narrowed `TestRemoveTouchesNoFileProvider`
     contract) — verified by asserting no `spaces.changed`/`SpaceResolve`/File Provider calls beyond
     what REMOVE already made before this work (none).
  10. A rescan that re-covers a marked-but-not-reaped document clears its `uncoveredAt` (interaction
      with ticket 14).
  11. ADD triggers an explicit `$unset` of `uncoveredAt` over the re-added folder's prefix, and that
      `$unset` — not backfill — is what clears the mark on already-present documents (a negative test:
      with the `$unset` suppressed, backfill leaves `uncoveredAt` set).

## Out of Scope

- A periodic / scheduled reaper's *coverage-derivation* (re-deriving which folders cover what on a
  schedule, independent of REMOVE) — the periodic sweep here only reaps time-expired marks; it does
  not re-derive coverage. A coverage-deriving periodic pass is a separate, larger effort if ever
  needed.
- Reaping `gallerySourceFolders` (already self-managing via `FindOneAndDelete`).
- Reaping `galleryPendingTombstones` (already TTL-bounded by migration `000004`).
- Reaping `gallerySequenceCounters`.
- Reaping `deleted:true` documents that are still covered by some user's folder — they still serve the
  delta feed.
- Proactive discovery of files deleted from disk without a `FileChangedEvent` — that is RESCAN's job
  (ticket 14). The reaper only acts on documents already flagged `deleted:true` (or `deleted:false`)
  once uncovered.
- Reaping `MetadataPending` placeholders specifically — they are reaped under the same uncovered rule
  as any other document; no special-casing.

## Further Notes

- The retention window's second purpose (beyond tombstone safety) is a grace period for folder
  reorganisation: remove-then-re-add within 30 days is cheap. This is a deliberate, documented
  property, not an incidental one.
- Reaping is idempotent: a document already reaped is simply absent; re-running the reaper on the same
  REMOVE produces no further change. Marking is idempotent (`uncoveredAt` is only set if absent).
- The lazy-reap behaviour is gone: the periodic sweep guarantees reaping within one tick interval of
  eligibility, regardless of folder-churn rate. The exact moment of reaping relative to the retention
  boundary is bounded by the tick interval (small, fixed) rather than by the rate of future REMOVEs.
- This effort intentionally does not introduce a new "uncovered" state into the read model's
  domain language — `uncoveredAt` is an internal storage watermark, not a concept surfaced to clients.
  The glossary in `CONTEXT.md` is not extended.
