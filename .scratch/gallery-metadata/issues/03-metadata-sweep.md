# 03 — Metadata sweep re-extracts outdated photos

**What to build:** Nothing re-extracts a photo once it is stored: `MetadataPending` documents (written by
backfill) stay pending until a live event touches the path, and an extraction improvement (ticket 01's
offset, ticket 04's location) never reaches existing photos. Rescan does not help — it only produces
`FileChangedEvent`s for files the File Index sees as new or changed.

This ticket adds `MetadataVersion int` to `GalleryPhoto` and a background sweep in the gallery service,
per the spec ("Metadata sweep"):

- Live ingestion writes the current `MetadataVersion`; backfill writes `0` (as it never extracts).
- On boot, a loop pages through non-deleted photos with `metadataVersion < current` (oldest `_id` first),
  opens each through the File Provider exactly as live ingestion does (`extractForEvent`), re-runs
  extraction, and upserts — clearing `MetadataPending`.
- `Seq` is bumped only when a field the delta feed carries actually changed.
- Concurrency 1, short pause between pages, no extra state: progress is the documents themselves, so a
  restart resumes.
- A file that cannot be opened keeps its old version, is logged, and is retried on the next boot; it never
  stalls the sweep.
- New migration: index on `metadataVersion`.
- The current version bumps with ticket 01's extraction change, so after deploy every existing photo gets
  its corrected Capture Date and offset.

The geo re-resolve pass (`GeoVersion`) is ticket 04; design the loop so a second, file-less pass can be
added beside it.

**Blocked by:** 01 (both touch extraction/upsert in `ingest.go`; the first version bump is 01's change).

**Status:** ready-for-agent

- [ ] A photo stored at an older `metadataVersion` is re-extracted on boot, ends at the current version,
      and its `Seq` is bumped once.
- [ ] A `MetadataPending` photo is fully extracted by the sweep and `metadataPending` becomes false.
- [ ] Re-extraction that produces identical feed-visible fields does not bump `Seq`.
- [ ] A photo whose file cannot be opened is skipped, keeps its version, and later photos are still
      processed.
- [ ] Deleted (tombstoned) photos are not swept.
- [ ] A live event racing the sweep for the same path ends in one document at the current version.
- [ ] Covered at the gallery integration-test boundary (NATS + Mongo testcontainers), following
      `backfill_integration_test.go`.
- [ ] Gates: `go test ./...` in `gallery`.
