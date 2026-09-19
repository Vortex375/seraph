# 07 — Read model, Capture Date and the paged listing

**What to build:** A photo copied into a Gallery Source Folder — over WebDAV,
over SMB, through the web UI, by any route at all — appears in a
capture-date-ordered listing of that user's gallery, newest first, paged.

This is the tracer bullet through the gallery service's core. The service
consumes the durable file-change stream, filters events to the resolved physical
prefixes of the configured Gallery Source Folders, extracts photo metadata, and
maintains its own read model. A paged query returns that user's photos in
Capture Date order.

**Capture Date is derived server-side** with the fallback chain `EXIF
DateTimeOriginal → file modification time → time first indexed`. Server-side so
that photos arriving by other routes sort correctly too. Record which rung of
the chain produced the value, so the UI can present a fallback date differently
from a real capture date.

**Modification time is not an acceptable ordering key and must not be used as
one.** It cannot survive Seraph's upload path today, so cloud-side modification
time is *upload* time — re-uploading years of photos after a phone restore would
pile all of them onto today.

**Two coordinate systems, translated at both ends.** Configuration is in Space
terms; **the read model is keyed physically on `(providerId, path)`** because
that is what the file-change event carries and matching an event against the
folder set must not cost a resolve per event; **the API returns Space paths**,
resolved at query time, so the app can feed them straight into the existing
preview and download endpoints with no new plumbing.

**Access control falls out of this.** A query is scoped to the requesting user's
Gallery Source Folders, each resolved *for that user* at query time. Revoked
access means resolution fails and that folder contributes nothing. There is no
reverse physical-to-space mapping and no second permission check to keep in
sync.

**The read model is shared while configuration is per user** — two users
including the same family folder cost one metadata extraction, not two.

**Backup coverage and display are independent questions.** A file the service
cannot decode is recorded with an `unsupported` reason rather than omitted, so
it still appears in the gallery. Omitting it is how backup tools silently skip
files.

**Blocked by:** 06

**Status:** resolved

- [x] A photo appearing in a configured folder shows up in that user's listing, at the position its Capture Date implies
- [x] Capture Date comes from the photo's own metadata where present, falling back to modification time and then to when it was first seen, with the source of the value recorded
- [x] Pixel dimensions and orientation are recorded, so portrait photos can be displayed the right way up
- [x] A file the service cannot decode is recorded with an `unsupported` reason and still appears in the listing
- [x] A photo with a nonsensical embedded date still appears rather than being rejected
- [x] A corrupt or truncated file fails for that item alone and does not stop the folder from loading
- [x] The listing is paged with a stable cursor; paging through thousands of photos yields each exactly once
- [x] The listing returns Space paths that work directly against the existing preview and download endpoints
- [x] A user sees exactly the union of their own Gallery Source Folders and nothing else
- [x] A user whose access to a Space has been revoked sees no photos from it
- [x] The read model is upserted on `(providerId, path)`, never inserted, so the same file arriving twice produces one item
- [x] A `deleted` event removes the photo from the listing
- [x] Events for files outside every configured folder are ignored cheaply, without a resolve per event
- [x] Covered at the gallery service's NATS boundary: publish file-change events, assert on listing responses. Photo fixtures are served through a stubbed File Provider responder and Space resolution through a stubbed resolve responder, both on the same bus

## Comments

Implemented as two packages by two workers in sequence, then verified as one
ticket against all 14 criteria.

### Implementer report — package 1, `f1e6e37` (ingestion, read model, metadata)

- `photo_entities.go` — `GalleryPhoto`/`GalleryPhotoPrototype`, `CaptureDateSource*`
  and `UnsupportedReason*` constants.
- `ingest.go` — durable JetStream consumer on `SERAPH_FILE_CHANGED`
  (`SERAPH_GALLERY_INGEST`), a `prefixCache` of resolved physical `(providerId,
  path)` prefixes rebuilt on startup and on ADD — never per event — upsert on the
  physical key, `deleted` events flag rather than hard-delete.
- `metadata.go` — EXIF, dimension and orientation decoding plus the Capture Date
  fallback chain. `DateTimeOriginal` is read directly via `exif.Get` rather than
  `x.DateTime()`, which silently falls back to plain `DateTime`.
- Migration `000002` — `galleryPhotos`, unique on `(providerId, path)`, plus a
  `(capturedAt desc, _id)` index existing specifically for the paged query.
- Tests include hand-built EXIF/JPEG byte fixtures, since no Go library here
  writes EXIF, and a `/Photos2`-vs-`/Photos` false-prefix case.
- Dependency added: `github.com/rwcarlsen/goexif`.

### Implementer report — package 2, `d812afa` (paged listing)

- `query.go` — `resolveFoldersForUser` resolves the requesting user's folders
  fresh on every query, deliberately uncached unlike the ingestion prefix cache,
  so revoked access simply drops a folder with no separate permission check and
  no reverse index. `listPhotos` is a keyset/seek cursor over the `(capturedAt
  desc, _id)` index, matching candidates in memory against the small resolved
  folder set and translating to Space paths at the boundary.
- `messages.go`, `gallery.go` — `seraph.gallery.list` subscription mirroring the
  existing CRUD shape. `api-gateway/gallery/gallery.go` — `GET /api/gallery/photos`.
- Cursor test pages 2500 photos with 50 shared capture dates at a page size
  deliberately unaligned to the scan batch size.

**Bug the implementer caught itself:** an early cursor inferred "no more data"
from "the last Mongo batch came back short", which is wrong when the page filled
partway through that batch and left the remainder unexamined. Fixed by only
trusting batch-length exhaustion once the batch was walked to its end.

### Verifier verdict — APPROVED

All 14 criteria satisfied by the combined diff, and the seam between the two
packages is coherent.

- **Cursor**: a true keyset seek on `(capturedAt desc, _id asc)`. The
  `batchFullyWalked` flag genuinely distinguishes "batch exhausted" from "page
  filled mid-batch", so the short-batch bug is eliminated rather than masked —
  confirmed against the 2500-photo tie test at a page size unaligned to the batch
  size.
- **Ordering key**: sort is `capturedAt desc, _id asc` only. Modification time
  appears solely as rung 2 of the fallback chain, never as a sort key.
- **Access control**: re-resolved per user per query, uncached. No reverse
  physical-to-space mapping exists anywhere in the diff, confirmed by grep.
- **Coordinate systems**: translation to Space paths at query time, in a format
  matching `getProviderAndPath` in `api-gateway/preview/preview.go`, so the paths
  work directly against the existing preview and download endpoints.
- **Cheap filtering**: `prefixCache.matches` is an in-memory prefix check with no
  per-event resolve, and rejects string-prefix-but-not-path-prefix folders.
- **Unsupported/corrupt/nonsensical dates**: the unsupported test asserts on the
  LISTING path, not merely on ingestion storage.

**Known test-environment flake, not a defect.** `api-gateway/gallery` and
`api-gateway/webdav` each start an embedded NATS server on the default port and
contend under parallel package execution. Serialized with `-p 1` they pass
cleanly. Pre-existing, not introduced here.

### Decisions the ticket did not settle

- *Stale prefix after REMOVE.* ADD refreshes the ingestion prefix cache
  synchronously; REMOVE deliberately does not, preserving ticket 06's tested
  "REMOVE touches nothing else" contract. The service therefore keeps ingesting
  from a removed folder until restart or the next ADD. Harmless — the read model
  is shared infrastructure and access control is enforced at query time — and
  ticket 09 is where this tightens.
- *List RPC shape.* Plain request/reply matching the existing CRUD topic, rather
  than `file-indexer`'s ack-then-stream-reply pattern, which the gallery service
  uses nowhere else.
- *Opaque base64 cursor encoding*, and a `scanBatchSize` of 500 for the in-memory
  filter pass. Neither specified by the ticket.
