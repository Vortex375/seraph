# Audio player UX: seek bar, queue, enqueue, track metadata and album art

Status: ready-for-agent

Builds on `.scratch/audio-player-engine/` (just_audio + `audio_service`, per-request authenticated
streaming). That engine work is a prerequisite and has landed on the `audio-player-engine` branch.

## Problem Statement

The audio player plays music, but using it feels bare and inflexible:

- The seek bar on the "now playing" screen is the old Material slider. It looks dated next to current
  Android music apps, and it doesn't show how much of the track has buffered.
- The user can't see what's coming up, and can't change it. There's no queue view, no way to reorder
  tracks and no way to drop a track.
- The only way to start music is the Play button in the file viewer. That replaces the whole queue with
  the current folder's audio files. A user can't add a song or an album to what is already playing.
- The "now playing" screen, the mini player and the system media notification show only the file name.
  There's no title, artist or album from the file's tags, and no album art.

## Solution

- The "now playing" screen uses the current Material 3 slider design, with a secondary track showing
  the buffered position. The mini player's progress bar uses the matching current Material 3 progress
  indicator.
- The "now playing" screen opens a **queue view**. It lists every track, highlights the one playing,
  and lets the user tap a track to jump to it, drag tracks to reorder them and swipe a track away to
  remove it. The playing track keeps playing through any edit, except when it is the one removed.
- In the file browser, an audio file, a selection of files, or a folder can be sent to the queue with
  **Play next** (right after the current track) or **Add to queue** (at the end). For a folder this
  means its own audio files, not subfolders, in name order. The file viewer's Play button keeps its
  current behaviour of replacing the queue with the folder.
- Tracks show their **tag metadata**: title, artist, album, album artist, year, track and disc number,
  genre. A new `audio-metadata` microservice reads the tags with TagLib (the existing `taglib` SWIG
  wrapper). The gateway exposes them to the app. Where a file has no tags, the file name is used as
  the title, as today.
- Tracks show **album art**, taken from the picture embedded in the file or, failing that, a cover image
  in the same folder (`cover`, `folder`, `front` or `album` with a `.jpg`, `.jpeg` or `.png` extension).
  Album art is a **Thumbnail** of the audio file, so the existing `/preview` URL serves it, with the
  thumbnailer's caching and share support. Without art, a placeholder icon is shown.
- Metadata and art appear in the "now playing" screen, the mini player, the queue view, and the system
  media notification / lock screen.

## User Stories

1. As a listener, I want the "now playing" seek bar to look like a current Material 3 slider, so that the app feels modern and consistent with Android.
2. As a listener, I want the seek bar to show how much of the track is buffered, so that I know how far I can jump without waiting.
3. As a listener, I want to drag the seek bar and have playback jump to where I let go, so that I can scrub through a track.
4. As a listener, I want the elapsed and total time shown next to the seek bar, so that I know where I am in the track.
5. As a listener, I want the mini player's progress bar to use the current Material 3 style, so that it matches the "now playing" screen.
6. As a listener, I want to open the queue from the "now playing" screen, so that I can see what's coming up.
7. As a listener, I want the playing track highlighted in the queue, so that I can see where I am.
8. As a listener, I want the queue to open scrolled to the playing track, so that I don't scroll to find it in a long queue.
9. As a listener, I want to tap a track in the queue to play it, so that I can jump ahead or back.
10. As a listener, I want to drag a track to a new position in the queue, so that I can change the order of what plays.
11. As a listener, I want the current track to keep playing uninterrupted while I reorder the queue, so that editing doesn't disrupt listening.
12. As a listener, I want to swipe a track away to remove it from the queue, so that a song I don't want won't play.
13. As a listener, I want removing the playing track to continue with the next track, so that the music doesn't stop.
14. As a listener, I want removing the last remaining track to close the player, so that I'm not left with an empty, stuck player.
15. As a listener, I want next and previous to follow the edited queue order, so that my edits take effect.
16. As a listener, I want an audio file's menu in the file browser to offer "Play next", so that I can hear a song right after the current one.
17. As a listener, I want an audio file's menu to offer "Add to queue", so that I can line up a song after everything else.
18. As a listener, I want to select several audio files and add them all with "Play next" or "Add to queue", so that I can build a playlist from a folder quickly.
19. As a listener, I want selected non-audio files to be ignored when enqueuing, so that a mixed selection doesn't break the queue.
20. As a listener, I want a folder's menu to offer "Play next" and "Add to queue", so that I can enqueue a whole album in one step.
21. As a listener, I want a folder's audio files added in name order, so that the album plays in track order when files are numbered.
22. As a listener, I want enqueuing while nothing is playing to start playback with what I added, so that "Add to queue" also works as "play this".
23. As a listener, I want brief feedback after enqueuing ("3 tracks added"), so that I know it worked.
24. As a listener, I want the file viewer's Play button to keep replacing the queue with the folder, so that "play this album now" stays one tap.
25. As a listener, I want "now playing" to show the track title from the file's tags, so that I see the real song name rather than "01-trk.mp3".
26. As a listener, I want to see the artist and album under the title, so that I know what I'm listening to.
27. As a listener, I want the year, track number and genre available on "now playing", so that I can see the details of the recording.
28. As a listener, I want files without tags to still show their file name, so that untagged files are not blank.
29. As a listener, I want the mini player to show title and artist, so that I can see what's playing while browsing files.
30. As a listener, I want queue rows to show title and artist, so that a queue of numbered files is readable.
31. As a listener, I want the lock screen and notification to show title, artist and album, so that I can see what's playing without opening the app.
32. As a listener, I want to see the album art on "now playing", so that the screen looks like a music player.
33. As a listener, I want album art from the picture embedded in the file, so that properly tagged files show their cover.
34. As a listener, I want album art from a cover image in the same folder when the file has none, so that album folders with a `cover.jpg` show art.
35. As a listener, I want a placeholder when there's no art, so that the layout doesn't jump or look broken.
36. As a listener, I want album art in the mini player and queue rows, so that I can recognise tracks at a glance.
37. As a listener, I want album art on the lock screen and notification, so that the phone shows what's playing like any music app.
38. As a listener, I want metadata and art to load without delaying playback, so that the music starts immediately.
39. As a web user, I want the same seek bar, queue, enqueue, metadata and art on the web app, so that both clients behave the same.
40. As a visitor to a share link, I want metadata and art for audio in the share, so that shared albums look as good as my own.
41. As a self-hoster, I want tag reading to run in its own service, so that the gateway stays free of native C++ dependencies.
42. As a self-hoster, I want album art cached like other thumbnails, so that browsing the queue doesn't re-read every audio file.
43. As a self-hoster, I want large embedded covers (several MB) to work, so that high-resolution art isn't silently dropped.
44. As a maintainer, I want queue edits implemented as a pure, tested model, so that index bookkeeping (the playing track's position after a move or removal) is right.
45. As a maintainer, I want the tag reader covered by a test on a real tagged file, so that a TagLib or wrapper change that breaks tag reading is caught.

## Implementation Decisions

### Seek bar (app)

- The "now playing" slider opts into the current (December 2023) Material 3 design. Set it through the
  app theme's `SliderThemeData(year2023: false)` (the per-widget `year2023` parameter is deprecated), or
  the per-widget flag if the theme route conflicts with other sliders. Use `secondaryTrackValue` for the
  buffered position.
- The handler already publishes `bufferedPosition` on `playbackState`. The controller exposes it.
- While dragging, the slider shows the drag position locally and seeks once, on release
  (`onChangeEnd`). It does not issue a seek on every `onChanged` as today.
- The mini player's `LinearProgressIndicator` uses the current Material 3 design (`year2023: false` or
  the theme equivalent).

### Queue model and editing (app)

- A pure Dart **queue model** owns the list of queue entries and the current index. Its operations each
  return the new list and the new current index:
  - `append(entries)`: adds at the end.
  - `playNext(entries)`: inserts after the current index, or at 0 when nothing is current.
  - `move(from, to)`: the current index follows the playing entry.
  - `removeAt(index)`: removing before the current index shifts it down; removing the current entry
    makes the next entry current (or the new last entry if it was last); removing the last remaining
    entry empties the queue.
  - `replace(entries, startIndex)`: what the file viewer's Play button does.

  The model has no Flutter, GetX or just_audio dependency. It is the test seam.
- The `audio_service` handler applies each model operation to both its `queue` stream and the
  just_audio playlist (`addAudioSources`, `insertAudioSources`, `moveAudioSource`,
  `removeAudioSourceAt`), so the playing track is not reloaded on a move or on an insert or removal
  elsewhere. Expose these through `audio_service`'s standard queue methods (`addQueueItems`,
  `insertQueueItem`, `removeQueueItemAt`) plus a custom move action (audio_service has no standard
  move). Removing the playing entry advances playback. Emptying the queue stops the player (same path
  as the close button).
- The **queue view** opens from the "now playing" screen, as a bottom sheet or a pushed screen (the
  implementer's choice, matching existing app patterns). It is a reorderable list: drag handle per row,
  swipe-to-dismiss per row, tap to jump (`skipToQueueItem`), playing row highlighted, initial scroll to
  the playing row.
- Queue entries keep their identity across edits by the file URL, which is already `MediaItem.id`.
  Duplicate files in one queue are allowed. The model operates on indices, not ids.

### Enqueue from the file browser (app)

- Each audio file's existing per-item popup menu (list view, and the grid view's equivalent) gains
  **Play next** and **Add to queue**. A folder's menu gains the same two entries.
- Selection mode's app bar gains the same two actions. They act on the selected audio files, ignore
  non-audio files, and are hidden or disabled when the selection contains no audio file. Selected
  folders contribute their audio files.
- A folder's audio files are read with one non-recursive directory listing (the file service's
  existing `readDir`), filtered with the existing `isAudioFile`, and sorted by name (natural sort, so
  `2` sorts before `10`, if a helper exists or is a few lines; otherwise plain name order).
- When the queue is empty or the player is closed, either action starts playback from the first added
  track.
- After enqueuing, a snackbar reports how many tracks were added.
- The file viewer's Play button is unchanged: it replaces the queue.

### `audio-metadata` microservice (server)

- A new Go module and service folder `audio-metadata/`, following the standard service layout (fx
  modules in `main.go`, `logging` / `messaging` / `config` / `tracing` / `service-discovery`,
  `viper` config defaults, a license header on every Go file). Add it to `go.work`.
- It reads files through the **File Provider** client (`fileprovider.NewFileProviderClient(...)`,
  `OpenFile`) and parses them with the existing `umbasa.net/seraph/taglib` wrapper
  (`NewWebdavFileStream` → `NewFileRef`). Use TagLib's fast audio-properties read style. Always free
  wrapper objects (`Delete`, `DeleteFileRef`).
- Two NATS request/response topics with Avro messages generated from a `messages_schema.avsc` through
  a `Makefile` (the thumbnailer's pattern):
  - **Tags request** `{providerId, path}` → `{error, errorClass, title, artist, album, albumArtist,
    genre, year, trackNumber, discNumber, durationMs, hasPicture}`. `errorClass` distinguishes "not an
    audio file / unsupported" from "unreadable" from "not found", in the style of the thumbnailer's
    `ErrorClass*`. Empty strings or zeros mean "no such tag".
  - **Picture chunk request** `{providerId, path, offset, length}` → `{error, errorClass, mimeType,
    totalSize, data (bytes)}`. It returns a slice of the file's front-cover picture, or the first picture
    if none is marked front cover (`taglib.Pictures`, `PictureType == "Front Cover"`). Clients read the picture by
    requesting successive chunks below the NATS max payload (follow the file-provider client's
    `MaxPayload` chunking). `errorClass` reports "no picture" separately.

  `// ponytail:` each chunk re-opens and re-parses the file. That's fine because the thumbnailer caches
  the result. Add a short-lived per-path picture cache if covers ever show up hot in traces.
- **Build and packaging.** The service is the only cgo build. The Dockerfile gets a separate build
  stage for it, run on the target platform (not `--platform=$BUILDPLATFORM`), based on the same
  `golang:1.26.5` image (Debian 13 trixie). That stage installs Debian's `libtag-dev` (TagLib 2.0.2) and
  `zlib1g-dev` and builds with `CGO_ENABLED=1`. TagLib is not built from source. Debian's 2.0.2 is the
  chosen version: the wrapper and its tests are verified against both 2.0.2 and upstream 2.3.2. The
  final image switches from `distroless/base-debian12` to **`distroless/cc-debian13`**, which adds
  libstdc++ and matches the build stage's glibc 2.41 (a Debian 13 build doesn't run on a Debian 12
  runtime). The runtime `libtag.so.2*` (and `libz.so*` if the image lacks it) are copied from the build
  stage into the image's library path. All other services keep the existing cross-compiled pure-Go
  build. Add the service to `docker-compose.yml` (and the dev compose, if it lists services). Verify
  that the image starts the service, not just that it builds.
- **Wrapper usage.** The `taglib` wrapper is regenerated with `make` in `taglib/` (see its README).
  Read pictures with `taglib.Pictures(ref)`: it returns mime type, description, picture type and
  byte-exact data, with all wrapper objects freed. Read text with `String.ToCString(true)` (UTF-8). Free
  every by-value result (`DeleteString`, `DeleteVariant`, ...). The service must not leak per request.

### Gateway tags endpoint (server)

- A new gateway handler `GET /audio/tags?p=<space path>` or `?s=<share path>`, with the same parameter
  rules as `/preview` (exactly one of `p` or `s`; `p` requires auth; `s` resolves the share). It
  resolves `providerId` and path exactly as the preview handler does. Extract that resolution from the
  preview handler into a shared helper first (prefactor), so it is not copied.
- It sends the tags request to `audio-metadata` and answers JSON
  `{title, artist, album, albumArtist, genre, year, trackNumber, discNumber, durationMs, hasPicture}`
  (omit empty fields). It answers 404 for "not found", 415 for "not an audio file / unsupported", and
  500 otherwise.

### Album art via the thumbnailer (server)

- When the thumbnailer's source file is not a decodable image (`image.DecodeConfig` reports
  `image.ErrFormat`), it asks `audio-metadata` for the file's picture (chunked, as above). It then
  decodes and resizes that picture through the existing thumbnail pipeline and stores it like any
  thumbnail. The JPEG output, cache key (path hash plus size), shares and `/preview` routing are all
  unchanged.
- If the file is audio but has no picture, the thumbnailer looks in the same directory (one
  `Readdir`) for a cover image: the name, case-insensitive, is `cover`, `folder`, `front` or `album`,
  the extension is `.jpg`, `.jpeg` or `.png`, and the first match by that priority wins. It thumbnails
  that image under the audio file's cache key.
- If the file is neither an image nor audio, the existing unsupported-format error class applies. The
  same goes for audio with no picture and no folder cover. The app shows its placeholder on any preview
  error.
- `// ponytail:` changing or adding a folder cover image does not invalidate cached audio-file
  thumbnails. Invalidation stays keyed on the audio file itself. Invalidate siblings on cover-file
  change events if stale art becomes a real complaint.

### Metadata and art in the app

- The file service gains `getAudioTags(path)`, which calls `/audio/tags` with the same `p`/`s` switch as
  `getPreviewUrl`, the bearer header and the existing 401/403 refresh-and-retry. It returns null on
  404/415/any failure, so the caller falls back to the file name.
- Tags are fetched lazily, never for the whole queue up front. They are fetched for the current item
  when it becomes current, and for queue rows as they are built. Results are cached in memory per file
  URL for the app session.
- When tags arrive for an item, the handler updates that queue entry's `MediaItem` (`title`, `artist`,
  `album`, `genre`, `extras` for year, track and disc number) and re-publishes `mediaItem` if it is the
  current one, so the notification and lock screen update.
- **Art URL.** `MediaItem.artUri` is the audio file's preview URL at a fixed size: one size,
  `galleryThumbnailSize` or a named "album art" size reused everywhere, so the thumbnailer cache is hit.
  `artHeaders` carries the current bearer, read when the item becomes current. Android's notification
  loads it once per item, so token expiry later doesn't matter. On web, the browser sends the session
  cookie and `artHeaders` is unused.
- In-app art (now playing, mini player, queue rows) uses the file service's existing authenticated
  preview-image path, with a placeholder icon as the `errorBuilder` and loading state.
- "Now playing" shows art (large, square), then title, artist · album, then a secondary line with
  year, track number and genre where present.

## Testing Decisions

Good tests here check observable behaviour through a module's public interface, not its internals.

- **Queue model (Dart unit tests)**, the main app seam. Cover, each asserting the resulting order and
  current index:
  - `append` with an empty queue and with a non-empty one.
  - `playNext` with nothing current, mid-queue and at the last item.
  - `move` before, across and after the current entry, and moving the current entry itself.
  - `removeAt` before, at and after the current entry, of the last entry while it is current, and of
    the only entry.
  - `replace`.

  Prior art: the plain-Dart unit tests under the app's `test/` (for example the stream-source and
  token-recovery tests), with no widget harness.
- **Tag reader (Go unit test)** in `audio-metadata`: open a tagged fixture through a `webdav.File`
  (`webdav.Dir`, as the taglib wrapper's own test does) and assert title, artist, album, genre and track
  number. Reuse or copy `taglib/test.mp3`. For pictures, reuse `taglib/testdata/picture.mp3` /
  `picture.flac` (embedded `testdata/cover.jpg`) and assert that a chunked read reassembles exactly
  `cover.jpg`'s bytes. Also assert that
  a non-audio file reports the "unsupported" error class.
- **Thumbnailer audio path (Go tests)**, following `TestCreateThumbnail` and the error-class tests in
  the thumbnailer: an audio file with embedded art produces a thumbnail; an audio file without art but
  with a `cover.jpg` sibling produces a thumbnail; one with neither reports the unsupported class; a
  non-audio, non-image file still reports unsupported. Provide `audio-metadata` in the test as a NATS
  responder (real or faked at the message level), in the style of the thumbnailer tests' existing NATS
  setup.
- **Not unit-tested:** the widgets (seek bar, queue view, menus), the handler's just_audio calls, and
  the gateway handler. These are verified on a device and through the build gates. The gateway
  endpoint may get an e2e test in the `api-gateway/e2e` style if one is cheap to add next to the
  existing ones. This is optional.
- **Gates.** For Dart: `flutter analyze` with zero issues, `flutter test`, and
  `flutter build web --release --base-href=/app/`. Add `flutter build apk` if `android/` is touched. For
  Go: `go build ./...` and `go test ./...` in each touched module. The Docker image must build and
  `audio-metadata` must start in compose.

## Out of Scope

- A music library or index (artists and albums browsing, search by tag), Subsonic API endpoints, and
  storing tags in the File Index. The `audio-metadata` service is designed to be reusable by those later.
- Editing tags or album art.
- Saving and loading named playlists, and persisting the queue across app restarts.
- Shuffle, repeat, gapless playback, crossfade, lyrics.
- Recursive folder enqueue.
- Desktop (Linux, Windows, macOS) and iOS clients.
- Invalidating cached album art when a folder cover image changes (see the ponytail note above).

## Further Notes

- The NATS default max payload is 1 MB, and embedded covers are often larger. Hence the chunked
  picture request instead of a single response.
- TagLib reads through the File Provider over NATS, so each tag read is a handful of small
  seek-and-read round trips. That's acceptable for lazily fetched, per-item tags. It is not suitable
  for scanning a library, which is out of scope here.
- `audio_service`'s `MediaItem` equality is weak (the controller already works around it with
  `firstRebuild`). Metadata updates must be published as new `MediaItem` instances.
