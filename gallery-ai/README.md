# gallery-ai

Analyses gallery photos with machine learning and stores the results in Postgres (pgvector).

It consumes `GalleryPhotoChangedEvent`s (JetStream stream `events.GalleryPhotoChangedStream`, durable consumer
`SERAPH_GALLERY_AI`), fetches a thumbnail from the thumbnailer, and asks the ML container for a CLIP image
embedding and the detected faces (with face embeddings). Results live in the `gallery_ai` database
(created on startup if missing, schema applied by embedded migrations).

On startup a background sweep re-analyses live photos whose stored model differs from the configured CLIP model.

## ML container

Inference is done by Immich's machine-learning image, pinned to
`ghcr.io/immich-app/immich-machine-learning:v3.4.2` in both compose files. The first request downloads the models
into the `/cache` volume (minutes).

To upgrade: change the tag in `docker-compose*.yml` and `mlImage` in `galleryai/ml_contract_test.go`, then run the
contract test against the new image (needs Docker, large image, slow on first run):

    SERAPH_ML_CONTRACT=1 go test ./galleryai -run TestMLContract -v -timeout 40m

## Configuration

Environment variables (`SERAPH_` prefix, `.` becomes `_`), plus the usual `SERAPH_NATS_URL`:

| Variable | Default | |
| --- | --- | --- |
| `SERAPH_GALLERY_AI_DB_URL` | required | e.g. `postgres://ai:ai@agents-db:5432/gallery_ai?sslmode=disable` |
| `SERAPH_GALLERY_AI_ML_URL` | `http://localhost:3003` | ML container |
| `SERAPH_GALLERY_AI_CLIP_MODEL` | `ViT-B-32__openai` | changing it triggers the sweep |
| `SERAPH_GALLERY_AI_FACE_MODEL` | `buffalo_l` | |
| `SERAPH_GALLERY_AI_FACE_MINSCORE` | `0.7` | |
| `SERAPH_GALLERY_AI_FACE_MAXDISTANCE` | `0.5` | max cosine distance for faces to be the same person |
| `SERAPH_GALLERY_AI_FACE_MINFACES` | `3` | faces (itself included) within that distance needed to start a new person |
| `SERAPH_GALLERY_AI_FACE_DEFERREDINTERVAL` | `5m` | how often the unassigned faces are re-clustered |
| `SERAPH_GALLERY_AI_MAXACKPENDING` | `2` | concurrent analyses |

The `gallery` service only publishes events when `SERAPH_AI_ENABLED=true`.

## Tags

Zero-shot content tags: each tag has English prompts; at startup their CLIP text embeddings are computed via the ML
container, averaged per tag and L2-normalised. A photo gets every tag whose cosine similarity to its stored image
embedding reaches the tag's threshold, stored with the score in `photo_tags`. Tagging happens in the same
transaction as storing the embedding.

Config (config file key `gallery.ai.tags`, replaces the whole default list when set):

    gallery:
      ai:
        tags:
          - tag: pet
            prompts: ["a photo of a dog", "a photo of a cat"]
            threshold: 0.25

Defaults: person, group, pet, animal, building, city, nature, beach, mountains, food, vehicle, document,
screenshot, night (`DefaultTags` in `galleryai/tags.go`), all at threshold `0.25`. **These thresholds are
uncalibrated**: 0.25 is a guess for CLIP ViT-B/32 (matches around 0.22-0.30, non-matches 0.15-0.20).

If the ML server is unreachable at startup, the tag embeddings are retried in the background with backoff; photos
analysed meanwhile get no tags. Once the embeddings are ready, a re-tag pass recomputes `photo_tags` for all live
photos from the stored embeddings (no image requests to the ML server) if the hash of the tag config plus CLIP
model, kept in `tag_state`, differs from the one the tags were last computed for. A photo stored without tagging
resets that hash, so the pass also catches up on those.

### Calibrating thresholds

Run the real ML container (compose or `docker run`, port 3003), then print per-tag scores for a directory of
images and choose thresholds by comparing them with what the photos show:

    SERAPH_TAG_CALIBRATE_DIR=/path/to/photos go test ./galleryai -run TestTagCalibration -v -timeout 30m

`SERAPH_GALLERY_AI_ML_URL` selects the ML server (default `http://localhost:3003`).

## People

Faces are grouped into persons with Immich's incremental algorithm (`handleRecognizeFaces`), right after a photo's
faces are stored. A face with at least `minFaces` faces (itself included) within `maxDistance` is a core face and
joins the person of its nearest matched face, or starts a new one. A non-core face is marked `deferred` and retried
by the periodic pass, where it may only join an existing person within `maxDistance`. That pass re-processes every
unassigned face (so a lone face still joins a person that appears later), at startup and then every interval, but only
if a face was assigned since the previous full pass. Faces with `manual = true` are never reassigned, but count as neighbours and lend their person.
All clustering runs under one Postgres advisory lock. Faces whose clustering failed or never happened (`clustered =
false`, e.g. after a crash) are picked up by the same pass. A person that loses all its
faces is deleted; one that loses its cover face gets another cover.

## API

Internal NATS request/reply topics (JSON, queue group = topic name; types in `galleryai/messages.go`). Every request
carries the caller's physical `prefixes` (`[{providerId, path}]`, path `/` = the whole provider); only live photos under
one of them are visible, and no prefixes match nothing. Every response has an `error` string. The gallery service
fronts these with user-scoped topics.

| Topic | Request | Response |
| --- | --- | --- |
| `seraph.gallery.ai.search` | `prefixes, text?, tag?, personId?, limit` (default 200, max 1000) | `items[{providerId, path, score}]`; `text` ranks by CLIP similarity, otherwise newest first |
| `seraph.gallery.ai.status` | `prefixes` | `analysed, pending, failed` (photos not yet delivered to gallery-ai are not counted) |
| `seraph.gallery.ai.people` | `prefixes` | `people[{id, name, photoCount, cover{providerId, path, box}}]`, counts and cover from visible photos only |
| `seraph.gallery.ai.person.rename` | `prefixes, id, name` (empty = unnamed) | `person`; `not found` if not visible |
| `seraph.gallery.ai.photo` | `prefixes, providerId, path` | `analysed, analysisError, tags[], faces[{id, box, personId, personName, manual}]` |
| `seraph.gallery.ai.face.assign` | `prefixes, faceId` and exactly one of `personId`, `newPersonName`, `unassign` | `face` |

## Existing photos

Photos that existed before gallery-ai was deployed arrive through gallery's one-time replay (see gallery).

## Licensing

The `buffalo_l` face model weights (InsightFace) are licensed for non-commercial research use only.
