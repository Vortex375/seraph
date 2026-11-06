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

**Status:** resolved

- [x] New Go module `audio-metadata/` in the standard service layout (fx, logging, messaging, config, tracing, service discovery, license headers), added to `go.work`.
- [x] Tag text is read with `ToCString(true)` (UTF-8), and every by-value wrapper result is freed (see `taglib/README.md`).
- [x] The tags request/response is Avro-generated from `messages_schema.avsc` through a `Makefile`, as in the thumbnailer. It returns the fields and `errorClass` values the spec lists. Files are read through `fileprovider` + the `taglib` wrapper, with the fast properties read style, and every wrapper object is freed.
- [x] Dockerfile: `audio-metadata` gets its own build stage on the target platform, from `golang:1.26.5` (Debian 13), with Debian's `libtag-dev` (TagLib 2.0.2) and `zlib1g-dev`, and `CGO_ENABLED=1`. TagLib is not built from source. The final image moves to `distroless/cc-debian13` (glibc match), with `libtag.so.2*` (and `libz.so*` if needed) copied in. Other services' builds are unchanged.
- [x] `docker-compose.yml` (and the dev compose, if it lists services) runs `audio-metadata`. The image builds, and the service starts and answers a tags request in compose.
- [x] The resolution of the `p`/`s` parameters into provider + path is extracted from the preview handler into a shared helper (prefactor). The preview behaviour is unchanged.
- [x] Gateway `GET /audio/tags?p=|s=` uses that helper and answers JSON (empty fields omitted), 404 for not found, 415 for not audio / unsupported, 500 otherwise. `p` requires auth.
- [x] The app's file service has `getAudioTags(path)` (share-aware, bearer, 401/403 refresh-and-retry, null on failure). Tags are fetched lazily for the current item and visible queue rows, never the whole queue, and cached in memory per file URL.
- [x] The handler publishes updated `MediaItem`s (`title`, `artist`, `album`, `genre`, `extras` for year, track and disc) as new instances. The notification and lock screen update when the current item's tags arrive.
- [x] "Now playing" shows the title, then artist · album, then a line with year, track number and genre where present. The mini player and queue rows show title and artist.
- [x] Go unit test: the tag reader on a tagged fixture (reuse or copy `taglib/test.mp3`) asserts title, artist, album, genre and track number. A non-audio file reports the unsupported class.
- [x] Gates: `go build ./...` and `go test ./...` in `audio-metadata`, `api-gateway` and `taglib`. `flutter analyze` reports zero issues; `flutter test`; `flutter build web --release --base-href=/app/`.

## Comments

**Implementation notes (2026-11-07):** a first attempt (rookie) stalled; this ticket was finished on top of it, with these corrections:
- **Workspace:** `audio-metadata` was never added to the root `go.work`, so the gateway's import of it made every module fail to resolve. Rookie's workarounds (stripped `api-gateway/go.mod`, a nested `go.work` with an absolute `replace`, stub modules in `.scratch/`) were removed. Internal modules are resolved through `go.work` only and are never `require`d.
- **Package split:** `audiometadata` is the pure-Go protocol (Avro messages, topics, error classes, a chunked `ReadPicture` client), so the gateway and the thumbnailer stay free of cgo. `tagreader` holds the TagLib reader and the responder; only the service binary imports it.
- **TagLib wrapper bugs fixed** (all from the original 2024 stream code; rookie's `free(): invalid size` aborts and "let the GC finalize it" workarounds traced back to these and to its own `ReadTags` freeing the stream before the `FileRef`):
  - `off_t` was unknown to SWIG, so `tell()`/`length()` handed C++ a pointer to Go memory. It is now declared as an integer, so offsets cross as `int64`.
  - Every `readBlock` leaked the returned `ByteVector`. It is now freed on the next read or on `Delete`.
  - `ReadBlock` never advanced the position, so `Tell()` was stale. It now uses `io.ReadFull` and tracks the offset.
  - SWIG adds no finalizers here, so anything not deleted leaks. `ReadTags(ref)` (next to `Pictures(ref)`) frees everything it creates. A 20,000-read soak showed flat RSS.
- **Not found:** the File Provider client opens lazily, so `audio-metadata` does a `Stat` first. That gives a clean `NotFound`, and a directory is reported as `Unsupported`.
- **Dockerfile:** the TagLib libraries are staged under their multiarch directory, not a hardcoded `x86_64-linux-gnu`, so the arm64 image works too.
- **App:** tags are fetched lazily (current item and queue rows), cached per file URL for the session, and re-applied when a file is queued again. Applied items are marked `tagged` so rows don't loop.
- **Verified in the dev compose stack:** `/audio/tags` returns tags for real files (names with spaces, `!`, `~`), 404 for a missing file, and 415 for an image.
- **Gates:** Go builds across the whole workspace. `taglib` and `audio-metadata` tests pass on Debian's TagLib 2.0.2 (`golang:1.26.5`) and on 2.3.2. Gateway `audio` tests pass. `api-gateway`'s `e2e` and `gallery` integration tests fail with "embedded NATS server did not become ready", identically on a clean `HEAD` checkout, so that failure predates this work. `flutter analyze` reports no issues, `flutter test` passes (423), and the web release build succeeds. The Docker image builds and `audio-metadata` starts in compose.
