# 04 — Gallery indexing reports Jobs

**What to build:** Per spec "Producers", in the gallery service:

- Queue Job `gallery.ingest` from consumer `SERAPH_GALLERY_INGEST`, polled every 10 s.
- Batch Job `gallery.backfill.<folderId>` from `runBackfill`: `done` = entries upserted, `total` unknown;
  `Complete` when the folder's backfill is marked done, `Fail` on an aborting error. A resumed backfill
  (`resumeIncompleteBackfills`) continues the same key.
- Batch Job `gallery.rescan.<folderId>` from `runRescan`, `statusMessage` naming the phase.
- Batch Job `gallery.replay` from `photo_replay.go`: `total` = photos to replay, `done` = published;
  `Fail` when the replay stops at a failed publish.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] Adding a Gallery Source Folder over a fixture with N photos yields `gallery.backfill.<id>` ending
      `completed` with `done` = N.
- [ ] A rescan yields `gallery.rescan.<id>` ending `completed`; a rescan against an unreachable provider
      ends `failed` with the error.
- [ ] With the ingest queue drained, `gallery.ingest` reports `idle` / `pending` 0.
- [ ] With AI enabled and a fresh replay, `gallery.replay` counts up to the photo count and completes; a
      publish failure ends it `failed`.
- [ ] Reporting never fails or slows the indexing itself beyond the reporter's own publishes.
- [ ] Gates: `go test ./...` in `gallery` with `DOCKER_HOST` set; confirm no `SKIP` in `-v` output.
