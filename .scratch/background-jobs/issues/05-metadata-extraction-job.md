# 05 — Metadata extraction reports a Job

**What to build:** Per spec "Producers": Batch Job `gallery.metadata.<folderId>` around
`healPendingMetadata` in `rescan.go`. Count the pending, non-deleted photos under the prefix first for
`total`; advance `done` per photo processed (extracted or skipped after an error); `statusMessage`
mentions how many were skipped. Skip the Job entirely when the count is 0.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] Rescanning a folder with N metadata-pending photos yields `gallery.metadata.<id>` going from
      `done` 0 / `total` N to `completed` with `done` = N.
- [ ] A photo whose extraction fails counts as done and is reported in `statusMessage`; the Job still
      completes.
- [ ] A folder with no pending photos publishes no `gallery.metadata.<id>` entry.
- [ ] Gates: `go test ./...` in `gallery` with `DOCKER_HOST` set; no `SKIP`.
