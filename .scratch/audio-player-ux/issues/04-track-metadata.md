# 04: Track metadata end to end (`audio-metadata` service, gateway endpoint, app)

**What to build:** "Now playing", the mini player, queue rows and the system notification / lock screen
show each track's tags: title, artist, album and, on "now playing", year, track number and genre.
Untagged files fall back to the file name. A new `audio-metadata` microservice reads the tags with the
existing TagLib wrapper through the File Provider. The gateway exposes them at `/audio/tags`. The app
fetches them lazily and caches them per file.

See the spec sections "`audio-metadata` microservice", "Gateway tags endpoint" and "Metadata and art
in the app" in `../spec.md`. This ticket builds the service with only the **tags** request. The
picture chunk request belongs to ticket 05.

**Blocked by:** 02: Queue view and editing (queue rows show the tags)

**Status:** ready-for-agent

- [ ] New Go module `audio-metadata/` in the standard service layout (fx, logging, messaging, config, tracing, service discovery, license headers), added to `go.work`.
- [ ] Tag text is read with `ToCString(true)` (UTF-8), and every by-value wrapper result is freed (see `taglib/README.md`).
- [ ] The tags request/response is Avro-generated from `messages_schema.avsc` through a `Makefile`, as in the thumbnailer. It returns the fields and `errorClass` values the spec lists. Files are read through `fileprovider` + the `taglib` wrapper, with the fast properties read style, and every wrapper object is freed.
- [ ] Dockerfile: `audio-metadata` gets its own build stage on the target platform, from `golang:1.26.5` (Debian 13), with Debian's `libtag-dev` (TagLib 2.0.2) and `zlib1g-dev`, and `CGO_ENABLED=1`. TagLib is not built from source. The final image moves to `distroless/cc-debian13` (glibc match), with `libtag.so.2*` (and `libz.so*` if needed) copied in. Other services' builds are unchanged.
- [ ] `docker-compose.yml` (and the dev compose, if it lists services) runs `audio-metadata`. The image builds, and the service starts and answers a tags request in compose.
- [ ] The resolution of the `p`/`s` parameters into provider + path is extracted from the preview handler into a shared helper (prefactor). The preview behaviour is unchanged.
- [ ] Gateway `GET /audio/tags?p=|s=` uses that helper and answers JSON (empty fields omitted), 404 for not found, 415 for not audio / unsupported, 500 otherwise. `p` requires auth.
- [ ] The app's file service has `getAudioTags(path)` (share-aware, bearer, 401/403 refresh-and-retry, null on failure). Tags are fetched lazily for the current item and visible queue rows, never the whole queue, and cached in memory per file URL.
- [ ] The handler publishes updated `MediaItem`s (`title`, `artist`, `album`, `genre`, `extras` for year, track and disc) as new instances. The notification and lock screen update when the current item's tags arrive.
- [ ] "Now playing" shows the title, then artist · album, then a line with year, track number and genre where present. The mini player and queue rows show title and artist.
- [ ] Go unit test: the tag reader on a tagged fixture (reuse or copy `taglib/test.mp3`) asserts title, artist, album, genre and track number. A non-audio file reports the unsupported class.
- [ ] Gates: `go build ./...` and `go test ./...` in `audio-metadata`, `api-gateway` and `taglib`. `flutter analyze` reports zero issues; `flutter test`; `flutter build web --release --base-href=/app/`.
