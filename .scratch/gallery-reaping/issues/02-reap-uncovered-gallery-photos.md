# 02 — Reap uncovered galleryPhotos documents

**What to build:** When a Gallery Source Folder is removed and no other user's folder covers the same
physical files, the underlying `galleryPhotos` documents become orphaned — invisible to every user,
never reaped, accumulating without bound. The same is true for `galleryPhotos` documents flagged
`deleted:true` once no folder covers them: their soft-delete tombstone is only ever served through a
covering folder's translation, so an uncovered `deleted:true` document serves no one.

This ticket adds a reaper that marks `galleryPhotos` documents no longer covered by *any* user's
Gallery Source Folder set with an `uncoveredAt` watermark, and deletes them once that watermark is older
than `DeltaTombstoneRetention` (30 days — the same window governing `galleryPendingTombstones`). Two
paths act on the watermark:

- **REMOVE** (immediate mark + opportunistic reap): after ticket 01's `refreshPrefixCache` updates the
  global prefix set, the reaper marks every document now uncovered (and not already marked) with
  `uncoveredAt = now`, then deletes any documents already past the retention window — so a burst of
  folder reorganisation is cleaned up promptly.
- **Periodic sweep** (time-expired reap): a background goroutine, started by `Start` and cancelled by
  `Stop`, ticks on a fixed interval and deletes documents where `uncoveredAt < now -
  DeltaTombstoneRetention`. It does not re-derive coverage; it only reaps aged marks, so infrequent
  REMOVEs do not leave orphans sitting indefinitely.

Covered `deleted:true` documents are never reaped — they still serve the delta feed for the covering
user(s). Reaping allocates no delta sequence, emits no `FileChangedEvent`, and writes no
`galleryPendingTombstones` row: the removing user's tombstone was already recorded by
`recordRemovalTombstones` (independent of `galleryPhotos`), and an uncovered document is not served by
the delta feed (no covering folder means `translate()` produces nothing). A folder re-added within the
retention window finds the marked documents still present and clears their `uncoveredAt`, so
remove-then-re-add is cheap; after the window, re-adding re-discovers the photos via backfill (the File
Index still holds them), so there is no data loss.

Un-marking on re-add is **not** a side effect of backfill: `backfillUpsert` uses `$setOnInsert` for
every field and writes nothing to an already-present document, so it would leave `uncoveredAt` set on a
marked-but-not-reaped document. ADD therefore runs an explicit `$unset` of `uncoveredAt` over the
re-added folder's prefix (a bulk update mirroring the mark's bulk `$set`), in the same background
hand-off that starts backfill. This is the third un-marking path alongside RESCAN re-cover and the
coverage recheck performed by the next REMOVE's mark pass (which sets `uncoveredAt` only on documents
not covered by any current prefix — so a re-covered document is naturally left alone by the mark, but
an explicit `$unset` is still required to clear a stale mark from a prior REMOVE).

**Blocked by:** 01 — REMOVE refreshes the global prefix cache (the reaper needs the refreshed prefix
set to compute accurate coverage at REMOVE time).

**Status:** ready-for-agent

- [ ] A new `uncoveredAt` field is added to `galleryPhotos` via migration `000005`, with an index that
      supports the mark and delete queries efficiently.
- [ ] REMOVE marks every `galleryPhotos` document not covered by any current folder prefix with
      `uncoveredAt = now` (only if not already marked), after ticket 01's prefix-cache refresh.
- [ ] REMOVE opportunistically deletes documents where `uncoveredAt < now - DeltaTombstoneRetention`.
- [ ] A periodic background sweep (started by `Start`, cancelled by `Stop`, tracked on the existing
      `wg`/`backfillCtx`) deletes documents where `uncoveredAt < now - DeltaTombstoneRetention` on a
      fixed tick interval short relative to `DeltaTombstoneRetention`.
- [ ] REMOVE of the *last* folder covering a physical path → the `galleryPhotos` documents under it are
      marked `uncoveredAt`, and reaped once the retention window elapses (time advanced in-test).
- [ ] REMOVE when another user's folder still covers the same physical path → documents are NOT marked
      `uncoveredAt`, NOT reaped, remain `deleted:false`.
- [ ] REMOVE when the same user has another folder covering the same physical path → NOT marked, NOT
      reaped.
- [ ] REMOVE, then re-add a covering folder within the retention window → documents still present,
      `uncoveredAt` cleared by an explicit `$unset` on ADD (not by backfill, which is `$setOnInsert`
      only and writes nothing to existing documents), visible again without re-backfill.
- [ ] The explicit `$unset` of `uncoveredAt` on ADD runs as a bulk update over the re-added folder's
      prefix, in the same background hand-off that starts backfill.
- [ ] REMOVE, advance past retention, reap, then poll the delta feed → the removing user still receives
      the folder-removal tombstone from `galleryPendingTombstones` (independent of the reaped row).
- [ ] A `deleted:true` uncovered document, past retention → reaped.
- [ ] A `deleted:true` covered document → NOT reaped, retained for delta-feed tombstone delivery.
- [ ] Reaped uncovered documents produce no delta event and allocate no sequence (no new
      `galleryPendingTombstones` row, no `seq` bump attributable to the reap).
- [ ] A RESCAN that re-covers a marked-but-not-reaped document clears its `uncoveredAt` (interaction
      with gallery-mode ticket 14).
- [ ] The reaper performs only local Mongo operations — no NATS request to any other service on either
      the REMOVE path or the periodic sweep (asserted at the gallery integration-test boundary).
- [ ] All cases covered at the gallery service's existing NATS + MongoDB integration-test boundary
      (testcontainers + embedded NATS); no new test seam introduced.
