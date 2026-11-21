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
| `SERAPH_GALLERY_AI_MAXACKPENDING` | `2` | concurrent analyses |

The `gallery` service only publishes events when `SERAPH_AI_ENABLED=true`.

## Existing photos

Photos that existed before gallery-ai was deployed arrive through gallery's one-time replay (see gallery).

## Licensing

The `buffalo_l` face model weights (InsightFace) are licensed for non-commercial research use only.
