# 05: Album art end to end (picture chunks, thumbnailer audio path, app)

**What to build:** Album art appears on "now playing" (large), in the mini player, in queue rows, and on
the system notification / lock screen. It comes from the picture embedded in the audio file, or else a
`cover` / `folder` / `front` / `album` `.jpg` / `.jpeg` / `.png` in the same folder, or else a
placeholder. Album art is a **Thumbnail** of the audio file, served by the existing `/preview` URL and
cached by the thumbnailer. Embedded covers of several MB work.

See the spec sections "`audio-metadata` microservice" (picture chunk request), "Album art via the
thumbnailer" and "Metadata and art in the app" in `../spec.md`.

**Blocked by:** 04: Track metadata end to end (the service exists, and the app's `MediaItem` enrichment path is in place)

**Status:** resolved

- [x] `audio-metadata` answers a picture chunk request `{providerId, path, offset, length}` → `{error, errorClass, mimeType, totalSize, data}`. The picture comes from `taglib.Pictures` (byte-exact, frees its wrapper objects): the front cover, or the first picture if there's no front cover. "No picture" has its own error class. Chunks stay below the NATS max payload, following file-provider's `MaxPayload` chunking.
- [x] The thumbnailer, when `image.DecodeConfig` reports `image.ErrFormat`, fetches the picture in chunks, then decodes, resizes and stores it like any thumbnail. The cache key, the JPEG output and the `/preview` and share routing are unchanged.
- [x] For audio with no picture, the thumbnailer uses a same-folder cover image (one `Readdir`, case-insensitive names, priority cover > folder > front > album, extensions .jpg/.jpeg/.png). For neither image nor audio, or audio with no art at all, it keeps the existing unsupported error class.
- [x] The `// ponytail:` notes from the spec are in the code: chunk requests re-parse the file, and folder-cover changes don't invalidate audio thumbnails.
- [x] The app sets `MediaItem.artUri` to the audio file's preview URL at one fixed album-art size, the same size everywhere so the cache is hit, with `artHeaders` carrying the current bearer. On web the cookie is used.
- [x] "Now playing" shows large square art. The mini player and queue rows show small art. All three use the authenticated preview image with a placeholder for loading and errors. The notification and lock screen show the art on Android.
- [x] Go tests: `audio-metadata` on `taglib/testdata/picture.mp3` (or a copy), whose embedded picture is `taglib/testdata/cover.jpg`, where a chunked read reassembles the exact bytes and the mime type is right. Thumbnailer tests, in the `TestCreateThumbnail` style with `audio-metadata` as a NATS responder: embedded art gives a thumbnail; a `cover.jpg` sibling gives a thumbnail; no art gives the unsupported class; a non-audio, non-image file gives the unsupported class.
- [x] Gates: `go build ./...` and `go test ./...` in `audio-metadata` and `thumbnailer`. `flutter analyze` reports zero issues; `flutter test`; `flutter build web --release --base-href=/app/`. The Docker image builds.

## Comments

**Implementation notes (2026-11-07):**
- `audiometadata.ReadPicture` reads a cover in `MaxPictureChunk` (512 KiB) chunks. The `tagreader` round-trip test reads a generated 1.3 MB cover in three chunks over real NATS and a File Provider.
- The thumbnailer's tests use a fake `audio-metadata` at the NATS message level (cgo-free) that serves `sample.jpg` (2.7 MB, six chunks) as an embedded picture.
- If `audio-metadata` is not running, the thumbnailer treats the file as unsupported, as before.
- `getPreviewUrl` now encodes the path (`Uri.encodeQueryComponent`, as the gallery already did), so file names with `&`, `#` or `+` work.
- audio_service's `MediaItem.copyWith` drops `artHeaders`, so the handler rebuilds the item with the current bearer on every publish. Android's notification fetches the art itself, and a token from queue-build time would have expired.
- Album art is one size everywhere (`galleryThumbnailSize`, 512), so the thumbnailer cache is hit.
- **Verified in the dev compose stack:** an MP3 without embedded art in a folder with `cover.jpg` gets a 512×512 JPEG of the cover from `/preview`.
