# Gallery AI: content tags, people and semantic search

Status: needs-triage

Phase: specification. Decided in conversation on 2026-11-21. Tickets in `issues/`.

Vocabulary: [CONTEXT.md](../../CONTEXT.md)

## Problem Statement

Gallery Mode can find photos by date and Place, but not by what is in them.
There is no way to ask for "photos with the dog", "photos of Anna" or "beach at
sunset". Every photo already has a 512 px Thumbnail made during warming, and
self-hostable open models can turn that Thumbnail into content tags, face
identities and a search embedding at low cost.

## Solution

Reuse Immich's `machine-learning` container (AGPL-3.0, like Seraph) unchanged
as a stateless inference server, and add one new Go microservice,
**`gallery-ai`**, that owns everything the container does not:

1. **Trigger.** The gallery service publishes a durable
   `GalleryPhotoChangedEvent` (physical key, `upserted` | `deleted`, `seq`)
   whenever a photo enters, changes in or leaves its read model. For photos
   already in the read model, gallery **replays** an `upserted` event per
   photo once (producer-side backfill). `gallery-ai` is that stream's only
   consumer and has no other input: it never pages or queries gallery.
2. **Input image.** For an upserted photo, `gallery-ai` asks the thumbnailer
   for the **512 px Thumbnail** over the existing `seraph.thumbnail.request`
   request/reply. That is a cache hit for every warmed photo; if warming has
   not reached the photo yet, the request produces the very same cached
   Thumbnail warming would have. No new image size, no re-decoding of the
   original.
3. **Inference.** One `POST /predict` per photo to the ML container, asking
   for the CLIP image embedding and for face detection + recognition.
4. **Storage.** Embeddings, faces, people and tags live in Postgres with
   pgvector, in a new `gallery_ai` database on the existing pgvector instance.
   Everything is keyed by the photo's **physical** (providerId, path), so a
   photo visible to several users is processed once.
5. **Tags.** Zero-shot classification: the photo embedding is compared with
   the text embeddings of a fixed, configurable prompt list ("a photo of a
   pet", "a photo of a building", …); tags above their threshold are stored.
6. **People.** Faces are grouped into Persons incrementally by the
   nearest-neighbour rule Immich uses (`handleRecognizeFaces`). A user names a
   Person once; from then on, photos of that Person are searchable.
7. **Search.** The user-facing APIs go through the **gallery service**, the
   only service that can resolve a user's Gallery Source Folders to physical
   prefixes and translate physical keys back to Space coordinates. Gallery
   calls `gallery-ai` with the user's physical prefixes and translates the
   results. The app joins the returned Space keys against its mirror.

Thumbnail size stays 512 px for now. It is enough for tagging, search and
portraits; small faces in group shots will be missed. Raising the warm size is
a later, separate decision (it regenerates every Thumbnail).

## User Stories

1. As a user, I can type a free-text description ("dog on the beach") in
   Gallery Mode and get my photos ranked by how well they match.
2. As a user, I can filter my gallery by a content tag (person, pet,
   building, nature, food, vehicle, document/screenshot, …).
3. As a user, I see a list of People found in my photos, each with a face
   and a photo count, and I can give a Person a name.
4. As a user, I can open a Person and see all my photos of them.
5. As a user, I can combine free text, a tag and a Person in one search.
6. As a user, I only ever get results from photos I can see in Gallery Mode;
   a Person who appears only in photos I cannot see does not appear in my list.
7. As a user, photos already in Seraph before this feature are analysed
   without me doing anything, and the app shows how far analysis has got.
8. As a user, a photo I delete disappears from search results and Person counts.
9. As a user, I can open a photo's details and see its tags and the faces
   found in it, each with its Person.
10. As a user, I can fix a face: assign it to another Person, to a new Person
    I name on the spot, or to no one. Automatic grouping never undoes my fix.
11. As the operator, the feature is one extra container (the ML server) plus
   one Seraph service; no API key, no outbound network after the models have
   downloaded once.
12. As the operator, I can leave `gallery-ai` and the ML container out of a
    deployment and Gallery Mode keeps working; only search and People are
    unavailable.

## Implementation Decisions

### ML container

- Image `ghcr.io/immich-app/immich-machine-learning`, **pinned to an exact
  release tag** (v3.4.2 at the time of writing). The `/predict` API is
  internal to Immich and unversioned; the request schema is strict
  (`extra="forbid"`, unknown keys → 422). Upgrades go through the contract
  test in ticket 03.
- `/cache` on a named volume (models download on first use). Default
  `MODEL_TTL=300` is fine.
- Request: multipart, `entries` = JSON, `image` = Thumbnail bytes, or `text`
  for a query:
  ```jsonc
  {"clip": {"visual": {"modelName": "<clip model>"}},
   "facial-recognition": {"detection": {"modelName": "buffalo_l", "options": {"minScore": 0.7}},
                          "recognition": {"modelName": "buffalo_l"}}}
  ```
  Response: `clip` is a JSON-encoded string of 512 floats;
  `facial-recognition` is a list of `{boundingBox{x1,y1,x2,y2}, embedding
  (JSON string), score}` in pixels of the submitted image, plus
  `imageWidth`/`imageHeight`.
- Models are configuration on `gallery-ai`: CLIP default `ViT-B-32__openai`
  (English queries). Switching to a multilingual CLIP model (e.g. an
  `nllb-clip` variant) is a config change plus a re-embed (see "Model
  version" below). Face model `buffalo_l`. Its weights are licensed for
  non-commercial research use only — acceptable for a self-hosted personal
  server; record it in the README.

### Gallery: change event (ticket 01)

- New type `events.GalleryPhotoChangedEvent{ProviderID, Path, Change
  ("upserted"|"deleted"), Seq}` with **physical** coordinates, published on
  durable JetStream stream `SERAPH_GALLERY_PHOTO_CHANGED`, subject
  `seraph.gallery.photo.changed`, `WorkQueuePolicy`, fire-and-forget like
  `dispatchThumbnailWarm`.
- Published from `upsertPhoto` (insert or content change), `backfillUpsert`
  (when `inserted`) and `markDeleted`. `Seq` is the photo's `seq` after the
  write, so the consumer can drop stale events.
- A metadata-only change (sweep re-extraction) does not publish: the pixels
  did not change.
- Gated by gallery config `ai.enabled` (default `false`). When `gallery-ai`
  is not deployed nothing is published, so the work-queue stream cannot grow
  without a consumer.

### Gallery: one-time replay of existing photos (ticket 02)

- On startup, when `ai.enabled` is set and the replay marker is not done,
  gallery walks `galleryPhotos` (non-deleted, ordered by `_id`) and publishes
  an `upserted` event per photo with its current `seq`. Same shape as the
  dotfile sweep: background goroutine, marker document in the `counters`
  collection, retried on the next restart on failure.
- The walk persists its last `_id` in the marker, so a restart resumes
  rather than starting over. Republishing a photo is harmless anyway: the
  consumer drops events whose `seq` it has already processed.
- Live events published during the replay interleave freely with it; `seq`
  ordering on the consumer side makes the result correct either way.
- Re-running the replay (e.g. after wiping the `gallery_ai` database) means
  deleting the marker document. No API for it.
- The stream holds replayed events until `gallery-ai` acks them, so the
  order in which gallery and `gallery-ai` are deployed does not matter.

### gallery-ai service (tickets 03–05)

- New Go module `gallery-ai/` (added to `go.work`, Dockerfile, compose),
  following the existing service shape: `fx`, `logging`, `tracing`, NATS +
  JetStream, config via viper.
- Postgres via `pgx`; schema migrations with `golang-migrate/migrate/v4`, the
  library every service already uses, with the `database/pgx/v5` driver and
  embedded `.sql` files via `source/iofs`. Mirror `mongodb.ApplyMigrations`
  (`mongodb/migrate.go`) in a few lines in `gallery-ai` rather than importing
  the Mongo helper module. Connection config `SERAPH_GALLERY_AI_DB_URL`.
- Schema (sketch):
  - `photos(provider_id, path, seq, deleted, model, analysed_at, error,
    PRIMARY KEY (provider_id, path))`
  - `photo_embeddings(provider_id, path, embedding vector(512))` + HNSW
    `vector_cosine_ops`
  - `photo_tags(provider_id, path, tag, score)`
  - `faces(id, provider_id, path, box_x1..y2 REAL (0..1, normalised to the
    Thumbnail), score, person_id NULL, manual, deferred, embedding
    vector(512))` +
    HNSW
  - `persons(id, name NULL, cover_face_id)`
- Face boxes are stored **normalised to 0..1**. Thumbnails are auto-oriented
  (`imaging.AutoOrientation(true)`), so the box applies to the photo as
  displayed, at any size.
- Consumer: durable consumer on `SERAPH_GALLERY_PHOTO_CHANGED`, explicit ack,
  bounded `MaxAckPending` (the ML call is the bottleneck; default 2).
  - `upserted`: ignore if stored `seq` ≥ event `seq`; else fetch the
    Thumbnail (`ThumbnailRequest{Width: 512, Height: 512}` →
    `fileprovider` open, as `api-gateway/preview` does), call `/predict`,
    replace the photo's embedding, tags and faces in one transaction, then
    run clustering for the new faces.
  - `deleted`: ignore if stored `seq` > event `seq`; else delete the photo's
    embedding, tags and faces, and keep the `photos` row as a tombstone
    (`deleted = true`, `seq`) so a stale `upserted` arriving later is still
    dropped. Persons left with no faces are deleted.
  - Thumbnailer `ErrorClassUnsupportedFormat`/`Corrupt`/`TooLarge`: record
    `error` on the photo row and ack (permanent). ML container unreachable or
    5xx: leave unacked for redelivery.
- **Model version:** `photos.model` records the CLIP model name. A sweep
  re-analyses rows whose model differs from the configured one. Faces are
  not re-clustered by a CLIP change.

### Tags (ticket 04)

- Config: list of `{tag, prompts[], threshold}`. Prompt text embeddings are
  computed once at startup through `/predict` (`text` + `clip.textual`) and
  averaged per tag.
- A photo gets every tag whose cosine similarity exceeds its threshold.
  Initial tag set: `person`, `group`, `pet`, `animal`, `building`, `city`,
  `nature`, `beach`, `mountains`, `food`, `vehicle`, `document`,
  `screenshot`, `night`.
- Thresholds are calibrated on real photos as part of ticket 04 (a small
  hand-labelled set; record precision per tag in the ticket).
- Changing the tag config re-tags from stored embeddings — no ML call needed.

### People clustering (ticket 05)

Port of Immich's `person.service.ts` `handleRecognizeFaces`. Per new face:

1. `matches` = faces within cosine distance `maxDistance` (default 0.5), up to
   `minFaces` (default 3), the face itself included.
2. Only itself matched (and `minFaces` > 1) → leave unassigned.
3. `isCore` = `len(matches) ≥ minFaces`. Not core and not yet deferred →
   re-queue it once, deferred (`faces.deferred`); a periodic pass, run when
   the consumer is idle, reprocesses deferred faces.
4. Person = first match that has one; else nearest face with a Person within
   `maxDistance`; else, if core, create a new Person.
5. Assign. A new Person's cover face is this face.

Faces with `manual = true` (see "Manual face assignment") are never
processed by these steps, but they do count as matches in step 1 and lend
their Person in step 4, so a correction also steers future grouping.

Clustering runs under one lock (`ponytail:` global lock, as Immich does). The
person set is **installation-wide**, not per user: faces belong to physical
photos, which users share through Spaces. Names are therefore shared too.

### Manual face assignment (ticket 07)

- Assignment is stored where automatic assignment is: `faces.person_id`.
  A manual change also sets `faces.manual = true`.
- Three operations on one face: assign to an existing Person, assign to a new
  Person created with a given name, unassign (`person_id` NULL, still
  `manual`, so grouping does not put it back).
- The face's photo must be under the caller's prefixes; a target Person must
  be visible to the caller (spec "User-facing APIs").
- A Person left with no faces is deleted; a Person whose cover face moved
  away gets another of its faces as cover; a new Person's cover is this face.
- Runs under the clustering lock.
- Known limit: when a photo's file changes, it is re-analysed and its faces
  replaced, so manual assignments on that photo are lost.

### User-facing APIs (tickets 06–07)

`gallery-ai` request/reply topics (internal, physical keys, every request
carries the caller's physical prefixes `[{providerId, path}]` and returns
only rows under one of them):

| Topic | Request | Response |
|---|---|---|
| `seraph.gallery.ai.search` | `prefixes, text?, tag?, personId?, limit` | `[{providerId, path, score}]` |
| `seraph.gallery.ai.people` | `prefixes` | `[{id, name, photoCount, cover{providerId, path, box}}]` |
| `seraph.gallery.ai.person.rename` | `prefixes, id, name` | person (error if not visible under prefixes) |
| `seraph.gallery.ai.photo` | `prefixes, providerId, path` | `{analysed, error, tags[{tag, score}], faces[{id, box, personId, personName, manual}]}` |
| `seraph.gallery.ai.face.assign` | `prefixes, faceId, personId? \| newPersonName? \| unassign` | the face after the change |
| `seraph.gallery.ai.status` | `prefixes` | `{analysed, pending, failed}` |

- Search semantics: `text` ranks by cosine distance to the text embedding;
  `tag` and `personId` are filters; with no `text`, order is newest `seq`
  first. `limit` default 200, max 1000.
- Prefix filter: `provider_id = $p AND (path = $prefix OR path LIKE
  $escaped_prefix || '/%')`, with `%`/`_`/`\` escaped.

The gallery service fronts each of these with a user-scoped topic
(`seraph.gallery.search`, `seraph.gallery.people`,
`seraph.gallery.people.rename`, `seraph.gallery.photo.analysis`,
`seraph.gallery.faces.assign`, `seraph.gallery.analysis.status`): it resolves
the user's folders (`resolveFoldersForUser`), passes their physical prefixes,
translates results back with `translate`, and drops rows that do not
translate. When `gallery-ai` does not answer, gallery returns
`error: "ai-unavailable"`.

Gateway routes (`api-gateway/gallery/gallery.go`, `apiGroup`):

- `GET gallery/search?q=&tag=&person=&limit=`
- `GET gallery/people`
- `PATCH gallery/people/:id` `{name}`
- `GET gallery/photos/analysis?providerId=&path=` (Space coordinates): tags
  and faces of one photo
- `PUT gallery/faces/:id/person` with exactly one of `{"personId": "…"}`,
  `{"newPersonName": "…"}`, `{"personId": null}`
- `GET gallery/analysis/status`

Results carry Space keys only; the app joins them to its mirror. Face crops
are drawn by the client from the Thumbnail and the normalised box — no new
image endpoint.

### App (tickets 08–10)

- Gallery Mode gets a search entry: free text, tag chips, Person chips.
  Results render as a grid of mirror rows in score order. Device-only photos
  are not searchable (they have not been analysed).
- A People screen: grid of named and unnamed Persons (face crop, count),
  rename, tap → that Person's photos.
- The photo viewer's details show the photo's tags and its faces (box
  overlay plus a face strip with Person names). Tapping a face offers:
  pick a Person, new Person with a name, or remove.
- When the server answers `ai-unavailable`, search, People and the viewer's
  analysis details are hidden.

## Out of Scope

- **Individual pet recognition.** The Immich container only finds human
  faces. Pets get the `pet` tag only. A follow-up spec would add a cat/dog
  detector plus an animal re-identification embedding (e.g. MegaDescriptor).
- Merging Persons and hiding Persons. Merging can be done face by face via
  manual assignment until it gets tedious.
- Editing tags by hand.
- Per-user Person names.
- Larger Thumbnails for better small-face recall.
- OCR search (the container supports it; not requested).
- Web app UI.

## Testing Decisions

- `gallery`: integration tests (existing testcontainers setup) that
  `upsertPhoto`/`backfillUpsert`/`markDeleted` publish the event with the
  right `seq`, that the replay publishes one event per non-deleted photo,
  resumes from its marker, and does nothing when `ai.enabled` is off.
- `gallery-ai`: integration tests with Postgres (pgvector image) via
  testcontainers and a **fake ML server** (httptest) returning canned
  embeddings, covering stale-`seq` drops, delete tombstones,
  prefix filtering and the clustering rules.
- One opt-in contract test against the real pinned ML container image,
  asserting the request is accepted and the response shape parses. Skipped
  unless `SERAPH_ML_CONTRACT=1`.
- Gallery-integration tests skip silently without Docker — check the test
  output counts, not just `ok` (see repo notes).
- App: `flutter analyze` zero issues, `flutter test`,
  `flutter build web --release --base-href=/app/`.

## Further Notes

- Physical vs Space keys: `gallery-ai` never sees users or Space paths; the
  gallery service is the only translator. This keeps access control in one
  place.
- Photos whose Gallery Source Folder is removed keep their `gallery-ai` rows
  until a `deleted` event arrives; they are unreachable because no user's
  prefixes cover them. Accepted.
