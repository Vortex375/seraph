# 01 — Gallery publishes a durable photo-changed event

**What to build:** `gallery-ai` needs to know when a photo enters, changes in or leaves the gallery read
model, keyed physically. Add `events.GalleryPhotoChangedEvent{ProviderID, Path, Change, Seq}` (`Change` is
`"upserted"` or `"deleted"`; physical coordinates; `Seq` = the photo's `seq` after the write) in `events/`,
next to `ThumbnailWarmRequest`, with stream `SERAPH_GALLERY_PHOTO_CHANGED` / subject
`seraph.gallery.photo.changed` constants in `events/topics.go`.

The gallery service ensures the stream exists (`WorkQueuePolicy`, like `ensureThumbnailWarmStream`) and
publishes fire-and-forget from:

- `upsertPhoto` (`gallery/gallery/ingest.go`) — on insert or content change, alongside
  `dispatchThumbnailWarm`;
- `backfillUpsert` (`gallery/gallery/backfill.go`) — only when `inserted`;
- `markDeleted` (`gallery/gallery/ingest.go`).

Metadata-sweep re-extraction does not publish. Publishing (and stream creation) is gated by gallery
config `ai.enabled`, default `false`. See spec "Gallery: change event".

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] A live Created event for a photo publishes one `upserted` event with physical coordinates and the
      stored `seq`.
- [ ] A Changed event for an existing photo publishes `upserted` with the new `seq`.
- [ ] A Deleted event (and the "file gone" fallback path) publishes `deleted` with the new `seq`.
- [ ] Backfill publishes only for newly inserted rows.
- [ ] A metadata sweep pass publishes nothing.
- [ ] With `ai.enabled` off, nothing is published.
- [ ] Publishing failure is logged and does not fail ingestion (same policy as `dispatchThumbnailWarm`).
- [ ] Gates: `go test ./...` in `gallery` and `events`, with the integration tests actually running
      (check the counts, not just `ok`).
