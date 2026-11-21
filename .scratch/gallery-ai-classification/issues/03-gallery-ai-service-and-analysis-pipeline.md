# 03 — gallery-ai service: consume events, analyse Thumbnails, store results

**What to build:** The new `gallery-ai` Go module and its analysis pipeline, per spec "ML container" and
"gallery-ai service":

- Module `gallery-ai/` in `go.work`, the Dockerfile and both compose files; the ML container
  (`ghcr.io/immich-app/immich-machine-learning`, pinned tag, `/cache` volume) in compose; a `gallery_ai`
  database on the existing pgvector instance.
- Postgres schema via `golang-migrate`: `photos`, `photo_embeddings` (HNSW cosine), `faces` (HNSW
  cosine, boxes normalised 0..1), `persons`, `photo_tags`. (Tags and persons are filled by tickets 04/05;
  create the tables here.)
- Durable consumer on `SERAPH_GALLERY_PHOTO_CHANGED` with explicit ack and `MaxAckPending` default 2.
  `upserted`: drop if stale by `seq`; fetch the 512 px Thumbnail via `seraph.thumbnail.request` + file
  provider open (as `api-gateway/preview/preview.go`); one `/predict` for CLIP visual + faces; replace
  the photo's embedding and faces in one transaction. `deleted`: drop if stale; delete the photo's
  embedding, tags and faces, keep the `photos` row as a tombstone (`deleted`, `seq`).
- Error policy: thumbnailer unsupported/corrupt/too-large → record on the photo row, ack. ML
  unreachable/5xx → no ack.
- No backfill logic here: existing photos arrive on the same stream through gallery's replay (ticket 02).
- Model-version sweep: re-analyse rows whose `model` differs from the configured CLIP model.
- README section: what the container is, the pinned tag, the `buffalo_l` non-commercial weights note.

**Blocked by:** 01

**Status:** resolved

- [x] With a fake ML server (httptest), an `upserted` event stores one embedding and the returned faces
      with boxes normalised by `imageWidth`/`imageHeight`.
- [x] An `upserted` event with a `seq` lower than the stored one is acked without calling the ML server.
- [x] A `deleted` event removes embedding, tags and faces; a later stale `upserted` does not resurrect them.
- [x] Thumbnailer `ErrorClassUnsupportedFormat` records the error and acks; ML 503 leaves the message
      unacked.
- [x] A replayed `upserted` event for a photo already analysed at that `seq` is acked without an ML call.
- [x] Changing the configured CLIP model re-analyses existing rows.
- [x] Opt-in contract test (`SERAPH_ML_CONTRACT=1`) against the pinned real image passes.
- [ ] `docker compose up` starts the ML container and `gallery-ai`; a newly uploaded gallery photo gets
      analysed end to end.
- [x] Gates: `go build ./...`, `go test ./...` in `gallery-ai`, integration tests running.

## Comments

2026-11-21 (coordinator): Resolved in 6e17d8d + the package B commit. Unit/integration suite runs (7 pass, contract test opt-in);
the contract test passed once against the real v3.4.2 image (no face in the test JPEG, so face parsing is only covered by the
fake). Not verified: a full `docker compose up` end-to-end run and the Docker image build — do that before deploying.
