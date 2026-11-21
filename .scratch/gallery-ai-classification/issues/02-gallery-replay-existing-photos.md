# 02 — Gallery replays change events for existing photos once

**What to build:** Photos already in the read model before ticket 01 never produced a change event.
Backfill them on the producer side, so `gallery-ai` only ever consumes the durable stream (spec "Gallery:
one-time replay of existing photos"):

- On startup, when `ai.enabled` is set and the replay marker is not done, a background goroutine walks
  `galleryPhotos` (non-deleted, ordered by `_id`) and publishes one `upserted`
  `GalleryPhotoChangedEvent` per photo with its current `seq`.
- Same shape as the dotfile sweep (`gallery/gallery/dotfile_sweep.go`): marker document in the
  `counters` collection; failure is logged and retried on the next restart. The marker also stores the
  last `_id` published, so a restart resumes instead of starting over.
- Re-running is done by deleting the marker document; document that in the gallery README/config docs.

**Blocked by:** 01

**Status:** resolved

- [x] With `ai.enabled` on and no marker, every non-deleted photo is published exactly once as
      `upserted` with its current `seq`; deleted photos are not.
- [x] After a restart mid-walk, the walk resumes after the last published `_id`.
- [x] Once done, a restart publishes nothing.
- [x] With `ai.enabled` off, nothing is published and no marker is written.
- [x] Deleting the marker makes the next startup replay again.
- [x] Gates: `go test ./...` in `gallery`, integration tests running (check the counts, not just `ok`).
