# Gallery dotfile exclusion and deletion propagation

Status: ready-for-agent

Related: gallery-mode (`.scratch/gallery-mode/`) — tickets 06 (gallery service and source
folders), 07 (read-model capture date and listing), 10 (delta feed with tombstones), 14 (rescan
folder); gallery-reaping (`.scratch/gallery-reaping/`) — reaper of uncovered read-model
documents; ADR 0001 (gallery read model and device mirror).

Vocabulary: [CONTEXT.md](../../CONTEXT.md)

## Problem Statement

A person using Gallery Mode sees "photos" that should not be there, and photos that they deleted
do not go away. Both symptoms share a root: the gallery trusts the File Index and the File Changed
event stream to tell it what exists, and both are leaking things that are not real photos.

The first leak is dotfiles. The atomic-PUT path stages every upload under a name beginning with `.`
(`.seraph-upload-*.part`), and WebDAV hides those staging files from PROPFIND listings. But that
hiding happens in the WebDAV layer, *above* the File Provider — so the File Provider still reports
staging files via `FileInfoEvent`, the File Index still indexes them, and the gallery still
ingests them as though they were photos. Interrupted and abandoned uploads consequently appear as
broken tiles in the gallery, and because WebDAV hides them, the user cannot even delete them
through a client. The same is true of any other dotfile a filesystem or client drops into a
Gallery Source Folder — `.DS_Store`, `.thumbnails`, editor lock files — none of which is a photo,
all of which the gallery happily indexes.

The second leak is deletions. When a file is removed through the File Provider's `RemoveAll`
operation — which is the path every deletion takes, whether over WebDAV, SMB, or the staging
sweeper — the File Provider performs the removal but emits no signal. The File Index only learns
that the file is gone when a *complete `Readdir`* later happens on the parent directory and the
indexer notices a previously-indexed child is missing. Until that listing happens, the File Index
still holds the file, the gallery's read model still holds it, and the delta feed still serves it
as a live photo. A photo the user deleted last week stays in the gallery simply because nobody
re-listed its parent directory. There is no periodic re-walk of Gallery Source Folders, and the
only user-triggered escape hatch is RESCAN.

The user experiences these as one brokenness: the gallery shows things that are not real and keeps
showing things that are gone. They expect a gallery to be an honest inventory — an interrupted
upload is not a picture, and a deleted photo is not still there.

## Solution

Gallery Mode stops indexing dotfiles, and deletion of a file by any route reaches the gallery
immediately.

**Dotfiles are excluded at the gallery boundary.** Both the live `FileChangedEvent` consumer and
the backfill paged-prefix query skip any entry whose final path segment begins with `.`. This is a
gallery-side filter: the File Provider and File Index remain general-purpose and continue to
index dotfiles, because a dotfile may be a legitimate file for some other consumer. The gallery is
specifically photos, and no dotfile is a photo. Existing dotfile documents already in the read
model are removed by a one-off sweep that tombstones them — bumping `seq` so the delta feed
delivers removal tombstones to every mirror, which then deletes the cloud-only rows and demotes
Synced rows to Device only. After the sweep, the existing reaper handles the uncovered tombstones
under its normal retention window.

**Deletions propagate from the source.** The File Provider emits a removal signal whenever it
performs a `RemoveAll` (covering every deletion route) or a `Rename` (as delete-at-old; the new
location appears through the normal path). The File Index consumes that signal and, for every file
it held beneath the removed path, publishes a `FileChangedEvent(deleted)` on the
`SERAPH_FILE_CHANGED` stream and removes it from the `files` collection. The gallery's existing
`markDeleted` path then sets `deleted:true`, bumps `seq`, and the delta feed delivers the tombstone
— the same path that already works for readdir-driven deletion detection, only now it fires the
moment a file is removed rather than the next time its parent is listed. The client mirror already
deletes Cloud only rows and demotes Synced rows to Device only on a tombstone, so deleted
cloud-only photos disappear and deleted photos that also live on the device degrade to Device only
rather than vanishing — exactly the Availability semantics the user expects.

A one-off reconcile against the File Index is explicitly **out of scope**: after the removal signal
ships, future deletions are reliable, and pre-existing orphans whose deletion was never signalled
are caught by the existing manual RESCAN action, which walks the File Provider and brings the File
Index up to date so the gallery learns.

## User Stories

1. As a photo owner, I want interrupted and abandoned uploads never to appear as photos in my
   gallery, so that the gallery is not littered with broken tiles from half-finished uploads.
2. As a photo owner, I want filesystem junk dotfiles — `.DS_Store`, lock files, thumbnail caches —
   kept out of my gallery, so that only actual photos appear.
3. As a photo owner who already has dotfile "photos" in my gallery today, I want them to disappear
   on their next sync without me having to find and delete each one, so that the fix also cleans
   up the past, not just the future.
4. As a photo owner, when I delete a photo from Seraph — over WebDAV, through the file browser, or
   by any other route — I want it to leave my gallery promptly, so that the gallery does not keep
   showing a photo I have already removed.
5. As a photo owner, when I delete the Seraph copy of a photo that also exists on my device, I want
   the gallery to keep showing it as Device only rather than removing it, so that freeing cloud
   space does not hide a photo I still have locally.
6. As a photo owner, when I delete a Cloud only photo, I want it gone from the gallery entirely,
   so that the gallery does not claim a photo exists when no physical copy of it remains anywhere.
7. As a photo owner, when a photo is renamed in Seraph, I want the old location to stop appearing
   in the gallery and the new location to take its place, so that a rename is reflected as a move
   and not as a duplicate or a lingering ghost.
8. As a gallery operator, I want the staging sweeper's removal of orphaned upload files to clean
   them out of the File Index and the gallery read model automatically, so that housekeeping does
   not require a manual directory listing to take effect.
9. As a Seraph administrator, I want the File Provider to be the single source of truth for "this
   file no longer exists", so that every consumer of file-change events — the gallery now, others
   later — learns about deletions through the same reliable channel rather than each reinventing
   deletion detection.
10. As a gallery developer, I want dotfile exclusion to live at the gallery ingestion boundary
    only, so that the File Index stays a general-purpose record and the gallery's "what is a photo"
    judgement is not spread across services.
11. As a gallery developer, I want the one-off dotfile cleanup to reuse the existing `markDeleted`
    / `withSequence` machinery, so that tombstones are produced through the same path as live
    deletions and the delta feed needs no new tombstone source.
12. As a gallery developer, I want the removal-signal expansion to happen in the File Index rather
    than the File Provider, so that one `RemoveAll` of a directory produces one signal upstream and
    the File Index fans it out per indexed file it held beneath that path.
13. As a gallery operator, I want the removal signal to be idempotent with the existing
    readdir-driven deletion detection, so that a later directory listing that would have detected
    the same deletion does nothing harmful and does not double-tombstone.
14. As a photo owner whose client was offline when a deletion happened, I want to receive the
    deletion tombstone when I next sync, so that the gallery on my device converges on the truth
    even if I was not connected at the moment of deletion.
15. As a photo owner, I want a deleted photo that is later re-created at the same path to reappear
    in the gallery, so that deletion is not a one-way door when the file genuinely comes back.

## Implementation Decisions

### Dotfile exclusion is gallery-only

The filter applies at two points in the `gallery` service, both using the same predicate — "the
final segment of the path begins with `.`":

- **Live ingest.** In the `FileChangedEvent` consumer's `handleMessage`, immediately after the
  existing `IsDir` reject and *before* the prefix-cache lookup, so both the `Deleted` and
  `Created`/`Changed` branches are covered. Skipping dotfiles only on the create branch would leave
  already-ingested dotfiles un-tombstoneable; rejecting them up front guarantees a dotfile never
  reaches either branch.
- **Backfill.** In the paged-prefix-query result loop, alongside the existing `IsDir` skip.

The File Provider and File Index are deliberately **not** changed: the File Index is a
general-purpose record of every known file, and a dotfile may be legitimate for a future
non-gallery consumer. Gallery Mode is the consumer that decides "this is not a photo", and that
judgement stays in the gallery.

### One-off dotfile cleanup reuses markDeleted, not a schema migration

Existing dotfile `galleryPhotos` documents must produce delta tombstones so mirrors remove them;
hard-deleting them without a tombstone would leave every client that already cached them showing
them forever. Tombstoning requires a per-document `seq` bump, which is application logic the
`markDeleted` / `withSequence` path already performs. A pure data migration cannot do this
correctly, so the cleanup is a **one-off startup sweep**: a background goroutine, tracked on the
gallery service's existing `wg`/`backfillCtx` (mirroring `startRemovalTombstoneSweep`,
`startSeqBump`, and `resumeIncompleteBackfills`), that finds every `galleryPhotos` document whose
final path segment begins with `.` and runs it through `markDeleted`. It runs once and is gated so
it does not repeat on every restart (a lightweight "sweep done" marker, e.g. a dedicated document
in an existing collection or a config-collection flag — the exact storage is an implementation
detail). The existing reaper then handles any uncovered tombstones under its normal retention
window; covered tombstones remain served by the delta feed until mirrors catch up, exactly as a
live deletion would.

### Removal signal: File Provider emits, File Index expands

The File Provider's `handleRemoveAll` today performs `s.fs.RemoveAll` and returns, publishing
nothing. It will instead publish a **removal signal** for the removed path after a successful
removal. `handleRename` publishes a removal signal for the old path; the new path appears through
the existing `FileInfoEvent` / `Readdir` path as normal, matching the gallery-mode decision that "a
rename surfaces as delete-at-old plus create-at-new."

The signal is carried over a contract extension in the `events/` Avro schemas — the precise shape
(a new `FileRemovedEvent` on its own subject, or an extension of `FileInfoEvent` with a deletion
marker and absent file info) is an implementation decision left to the ticket, with the constraint
that it is additive and does not break existing consumers. The `events/` Makefile codegen is run to
regenerate Go sources.

The **File Index fans the signal out**, not the File Provider: one `RemoveAll` of a directory
produces one upstream signal, and the File Index's consumer expands it into a per-file
`FileChangedEvent(deleted)` for every file it held at or beneath the removed path, deleting each
from the `files` collection. This keeps the File Provider simple and lets the File Index remain the
authority on "what did the index hold beneath this path". The deletion event is published through
the same `publishChange` path used by readdir-driven deletion detection, so the gallery and every
other consumer see no difference between a signalled deletion and a discovered one.

**Idempotence with readdir-driven detection.** After the signal deletes a file from the `files`
collection, a later complete `Readdir` on the parent that would have detected the same file as
missing finds nothing to delete — the `handleReaddirComplete` path is a no-op for an already-removed
file. No double event, no double tombstone.

**Re-creation is unchanged.** A `Created`/`Changed` event for a previously-deleted path runs
through `upsertPhoto`, which writes `deleted:false` and resurrects the read-model document — the
existing re-creation semantics. The removal signal does not change this; it only makes the
deletion half reliable.

### No client change

The Flutter mirror already applies delta tombstones correctly: a tombstone on a Cloud only row
deletes it, and a tombstone on a Synced row demotes it to Device only
(`gallery_mirror.dart:391-415`), with tests covering both cases. The removal-signal change means
the client simply starts receiving the tombstones it was missing; no Dart work is required and
none is in scope.

### No new collections, no new migrations

The dotfile filter is code-only. The one-off dotfile cleanup is a code-level startup sweep, not a
`migrations/*.json` file (it needs `seq` allocation). The removal signal is a contract and
consumer change. None of the three tickets adds a Mongo collection or index; the next migration
number remains `000005` for whoever needs it next.

## Testing Decisions

- **Primary seam: the gallery service's existing NATS + MongoDB integration-test boundary**
  (testcontainers + embedded NATS), as used by `ingest_integration_test.go`,
  `backfill_integration_test.go`, `delta_integration_test.go`. The dotfile filter and the one-off
  sweep are observed through the `galleryPhotos` collection and the delta feed, never through the
  filter's internal shape.
- **What makes a good test here.** Tests assert external behaviour: a dotfile event does not
  produce a `galleryPhotos` document; a dotfile in a backfill page does not produce one; after the
  sweep, dotfile documents that were present are `deleted:true` with a bumped `seq` and the delta
  feed delivers their tombstones. They never assert on the filter predicate directly.
- **Prior art to extend.**
  - `TestEventsOutsideConfiguredFoldersAreIgnored` (`ingest_integration_test.go`) — the shape for a
    new "dotfile events are ignored" test on the live path.
  - `TestBackfill*` family — the shape for a backfill-page dotfile-skip test.
  - `TestDeletedEventRemovesPhotoFromListing` and `TestDeltaDeliversTombstoneOnDelete`
    (`delta_integration_test.go`) — confirm the sweep's tombstones behave identically to live
    deletion tombstones.
- **New seam for the removal signal: the file-provider ↔ file-indexer contract.** Assert that a
  `RemoveAll` (and a `Rename`) produces a `FileChangedEvent(deleted)` on the
  `SERAPH_FILE_CHANGED` stream for every file the File Index held beneath the removed path,
  without any `Readdir` occurring. Assert the `files` collection no longer holds those entries.
  Assert idempotence: a subsequent complete `Readdir` on the parent emits no further deletion
  event for them. Where a multi-service file-provider → file-indexer → gallery integration test is
  impractical, rely on the gallery's existing deletion tests (`TestDeletedEventRemovesPhotoFromListing`,
  `TestDeltaDeliversTombstoneOnDelete`) to confirm the downstream path is unchanged — the gallery
  cannot tell a signalled deletion from a discovered one, by design.
- **Required test cases.**
  1. A `Created` event for a dotfile path under a configured folder → no `galleryPhotos` document.
  2. A `Changed` event for a dotfile path → no document.
  3. A `Deleted` event for an already-ingested dotfile path → still no document created (the filter
     rejects it before `markDeleted`), confirming the filter covers both branches. (Existing
     ingested dotfiles are cleaned by the sweep, not by live events.)
  4. A backfill page containing a dotfile entry → no `galleryPhotos` document for it.
  5. The one-off sweep, given pre-existing dotfile `galleryPhotos` documents, marks them
     `deleted:true` with bumped `seq`, and a subsequent delta poll delivers their tombstones.
  6. The one-off sweep does not touch non-dotfile documents.
  7. The one-off sweep does not re-run after it has completed (the "sweep done" marker is honoured).
  8. A `RemoveAll` of a single indexed file → a `FileChangedEvent(deleted)` for that path on the
     stream, the file absent from the `files` collection, with no `Readdir` issued.
  9. A `RemoveAll` of a directory containing multiple indexed files → one deletion event per file
     beneath it.
  10. A `Rename` → a deletion event for the old path (and no spurious deletion for the new path).
  11. A `RemoveAll` of a path the File Index does not hold → no deletion event (idempotent no-op).
  12. After a signalled deletion, a complete `Readdir` of the parent → no further deletion event
      for the already-removed file (idempotence with readdir-driven detection).
  13. A `Created` event for a path that was previously signalled-deleted → the read-model document
      is resurrected (`deleted:false`), confirming re-creation semantics are unchanged.

## Out of Scope

- **Filtering dotfiles in the File Index or File Provider.** The File Index remains a
  general-purpose record; the gallery is the consumer that decides what is a photo.
- **A one-off reconcile of the gallery read model against the File Index** for pre-existing
  orphans whose deletion was never signalled before the removal signal shipped. After the signal
  ships, future deletions are reliable; pre-existing orphans are caught by the existing manual
  RESCAN action, which walks the File Provider and brings the File Index up to date.
- **A periodic re-walk of Gallery Source Folders** for proactive deletion discovery. The removal
  signal makes deletion propagation immediate; a periodic re-walk is not needed for correctness.
- **Any client-side change.** The Flutter mirror already applies tombstones correctly.
- **Reaping covered `deleted:true` tombstones.** The existing reaper reaps only uncovered
  documents; covered tombstones (including the sweep's) remain served by the delta feed until
  mirrors catch up, under the same rules as any live deletion. Changing that is a separate concern.
- **Extending the removal signal to other File Provider operations** beyond `RemoveAll` and
  `Rename` (there are none today that remove files).
- **A new Mongo migration.** None of the three changes adds a collection or index.

## Further Notes

- The two fixes are independent and can land in either order, but the one-off dotfile sweep (03)
  is blocked by the dotfile filter (01) so the sweep does not race with re-ingestion of the very
  dotfiles it is removing.
- The removal signal (02) is unblocked and is the larger of the three; it touches the `events/`
  Avro contract and two Go services, but the gallery side needs no change because it already
  handles `FileChangedEvent(deleted)` correctly.
- The dotfile filter's "final path segment begins with `.`" predicate deliberately matches on the
  *basename*, not the whole path, so a legitimate folder whose name begins with `.` is unaffected
  — only files are filtered, and only by their own name. The `IsDir` check already runs before the
  dotfile check, so a dotfile-named directory is skipped as a directory, not filtered as a dotfile
  file.
- The staging-file symptom (`.seraph-upload-*.part` tiles) is the most visible instance of the
  dotfile problem and is fully resolved by the filter + sweep; the staging sweeper's own removal of
  orphaned uploads will additionally now produce deletion signals (ticket 02) that clean the File
  Index, where today it leaves the File Index stale until a listing happens.
