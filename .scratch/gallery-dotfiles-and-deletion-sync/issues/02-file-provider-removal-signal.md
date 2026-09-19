# 02 — File Provider emits a removal signal; File Index propagates it as a deleted FileChangedEvent

**What to build:** Deleting a file through the File Provider's `RemoveAll` — the path every
deletion takes, whether over WebDAV, SMB, or the staging sweeper — produces a reliable
`FileChangedEvent(deleted)` on the `SERAPH_FILE_CHANGED` stream immediately, without waiting for a
later directory listing to discover the file is gone. The File Provider emits a removal signal on
successful `RemoveAll` (and `Rename`, as delete-at-old; the new location appears through the
existing FileInfoEvent/Readdir path). The File Index consumes that signal and, for every file it
held at or beneath the removed path, publishes a `FileChangedEvent(deleted)` through the existing
`publishChange` path and removes it from the `files` collection. The gallery needs no change: its
existing `markDeleted` path then tombstones the photo and the delta feed delivers the tombstone,
exactly as it already does for readdir-driven deletion detection. Clients delete Cloud only rows
and demote Synced rows to Device only on the tombstone — the Availability semantics the user
expects.

**Blocked by:** None — can start immediately. Independent of ticket 01 (different services).

**Status:** resolved

- [ ] The File Provider's `RemoveAll` handler publishes a removal signal for the removed path after
      a successful removal (read-only providers that refuse with `ErrPermission` publish nothing).
- [ ] The File Provider's `Rename` handler publishes a removal signal for the old path; the new
      path is not signalled as a deletion (it appears via the normal path).
- [ ] The removal signal is carried over an additive contract extension in the `events/` Avro
      schemas (a new event/subject, or an extension of `FileInfoEvent` with a deletion marker and
      absent file info — the precise shape is an implementation decision); the `events/` Makefile
      codegen is run to regenerate Go sources. Existing consumers are not broken.
- [ ] The File Index consumes the removal signal and fans it out: one `RemoveAll` of a directory
      produces one `FileChangedEvent(deleted)` per file the File Index held at or beneath that
      path, deleting each from the `files` collection. The File Provider stays simple; the File
      Index remains the authority on "what did the index hold beneath this path".
- [ ] A `RemoveAll` of a single indexed file → one `FileChangedEvent(deleted)` for that path on the
      stream, the file absent from the `files` collection, with no `Readdir` issued.
- [ ] A `RemoveAll` of a directory containing multiple indexed files → one deletion event per file
      beneath it.
- [ ] A `Rename` → a deletion event for the old path and no spurious deletion for the new path.
- [ ] A `RemoveAll` of a path the File Index does not hold → no deletion event (idempotent no-op).
- [ ] Idempotence with readdir-driven detection: after a signalled deletion, a subsequent complete
      `Readdir` of the parent emits no further deletion event for the already-removed file.
- [ ] Re-creation is unchanged: a `Created`/`Changed` event for a previously signalled-deleted path
      resurrects the gallery read-model document (`deleted:false`), confirming the removal signal
      does not alter re-creation semantics.
- [ ] The gallery's existing `TestDeletedEventRemovesPhotoFromListing` and
      `TestDeltaDeliversTombstoneOnDelete` continue to pass unchanged — the gallery cannot tell a
      signalled deletion from a discovered one, by design.

## Implementation record

Base SHA: bbf29ea5972d162dd5243bd2a801c982d7ffea3b
Implementer report:
- File-provider `RemoveAll`/`Rename` publish a new additive `FileRemovedEvent` (Avro schema, regenerated via `make`) on `seraph.fileprovider.*.fileremoved`, captured on the existing `SERAPH_FILE_INFO` stream so the indexer's single durable consumes it in order.
- File-indexer `handleMessage` branches on subject; `handleFileRemoved` finds every file at/beneath the path via the same point-lookup + bounded descendant-range filters the list path uses, publishes a `FileChangedEvent(deleted)` through the existing `publishChange` for each, and deletes them from `files`.
- Idempotence confirmed by reading `handleReaddirComplete` (its `$nin` filter cannot match an already-absent file) and pinned with a test. Read-only providers return `ErrPermission` before publishing. Gallery's deletion tests pass unchanged.
Decision the ticket left open: chose a new `FileRemovedEvent` record on its own subject (reusing `SERAPH_FILE_INFO`) over extending `FileInfoEvent` with a deletion marker — cleaner semantics, zero risk to existing FileInfoEvent consumers.
Files: events/{schema.avsc,events.go,topics.go}, file-provider/fileprovider/server.go, file-indexer/fileindexer/{consumer.go,export_test.go,consumer_integration_test.go}.
Out-of-scope note: the removal path does not clean orphaned `readdir` collection entries beneath a removed directory — matches today's readdir-driven behavior; worth a follow-up if `readdir` growth matters.

Verifier verdict: APPROVED. All acceptance criteria verified against the diff. File-provider publishes on success only (read-only skips); additive events schema with `FileInfoEvent` untouched; file-indexer fans out via existing `publishChange` using same prefix filters as the list path; single-file, directory, rename, unknown-path, and idempotence cases all tested; re-creation and gallery untouched; gallery deletion tests pass. Tooling clean across events, file-provider, file-indexer; full file-indexer suite passes under testcontainers.
