# 07 — AI classification reports Jobs

**What to build:** Per spec "Producers", in `gallery-ai`:

- Queue Job `gallery-ai.analysis` ("AI classification") from consumer `SERAPH_GALLERY_AI`, polled every
  10 s; `statusMessage` like "4,210 analysed, 12,876 waiting" (analysed = non-deleted rows with a model).
- Batch Job `gallery-ai.tagging` around the re-tag pass in `tags.go` (`total` = photos to re-tag).
- Batch Job `gallery-ai.clustering` around the timed full clustering pass in `people.go` (`total` =
  unassigned faces checked); only when the gate lets the pass run.

**Blocked by:** 01

**Status:** resolved

- [x] With photo-changed events queued, `gallery-ai.analysis` reports `running` with a falling `pending`,
      then `idle`.
- [x] Changing the tag config yields `gallery-ai.tagging` ending `completed` with `done` = `total`.
- [x] A gated clustering pass that is skipped publishes nothing; one that runs ends `completed`.
- [x] With the ML container down, analysis keeps reporting its backlog (it does not go `idle` while
      messages are being NAK'd).
- [x] Gates: `go test ./...` in `gallery-ai` with `DOCKER_HOST` set; no `SKIP` beyond the opt-in ML tests.
