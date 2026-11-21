# 04 — Zero-shot content tags

**What to build:** Per spec "Tags": a configurable list of `{tag, prompts[], threshold}`; prompt text
embeddings computed at startup via `/predict` (`text` + `clip.textual`, same CLIP model), averaged per
tag; every analysed photo gets the tags whose cosine similarity exceeds the threshold, stored in
`photo_tags` with the score. A tag-config change re-tags all photos from stored embeddings without
calling the ML server.

Calibrate thresholds on real photos: hand-label ~30 photos per tag from the maintainer's library, pick
thresholds, and record per-tag precision/recall in the Comments below. This calibration needs a human to
label photos.

**Blocked by:** 03

**Status:** ready-for-human

- [x] Analysis stores tags above threshold; none below.
- [x] Changing a threshold in config re-tags existing photos at startup with no ML calls (fake server
      asserts zero visual requests).
- [ ] Calibration results for the initial tag set are recorded in this ticket.
- [x] Gates: `go test ./...` in `gallery-ai`.

## Comments

2026-11-21 (coordinator): Implementation committed. All defaults use the uncalibrated threshold 0.25. Remaining
human step: run the calibration helper (`SERAPH_TAG_CALIBRATE_DIR=... go test ./galleryai -run TestTagCalibration -v`,
see gallery-ai/README.md) on hand-labelled photos, set per-tag thresholds in config, record precision here.
