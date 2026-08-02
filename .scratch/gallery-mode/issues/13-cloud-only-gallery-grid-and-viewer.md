# 13 — Cloud-only chronological grid and viewer

**What to build:** **Phase 1 ships here.** Opening Gallery Mode shows the user's
photos in Seraph as a grid of Thumbnails ordered by Capture Date, newest first,
scrolling back through the whole collection. Tapping one opens it full screen.
This works on every platform — Android, iOS, desktop and web — with every item
*Cloud only* and no upload anywhere in sight.

The gallery view is a 22-line stub today; this replaces it. Thumbnails come from
the existing preview endpoint and full-resolution images from the existing
download endpoint, using the Space paths the gallery API returns — no new
media-serving endpoint is introduced.

Upload and device-related controls are hidden rather than shown broken, since
nothing on this platform can perform them yet.

**Blocked by:** 12

**Status:** resolved

- [x] Opening Gallery Mode shows a Thumbnail grid ordered by Capture Date, newest first
- [x] Scrolling back through thousands of photos stays smooth and does not stall on the network
- [x] Scroll position and item count stay stable as more items load — the grid does not shift under the user's thumb
- [x] Date headings show roughly where in history the user is
- [x] A scrubber allows jumping to a point in time
- [x] Tapping a photo opens it full screen; swiping moves through photos in the same order as the grid
- [x] A photo recorded as unsupported shows a placeholder with the reason rather than being hidden or shown broken
- [x] Photos display in their correct rotation
- [x] A photo's details show which Seraph folder it lives in
- [x] With no network, the gallery still opens and shows already-cached Thumbnails
- [x] The view opens quickly on first launch after an update
- [x] The same view works on iOS, desktop and web, with upload controls absent
- [x] Gallery logic is verified at the mirror seam, not in widget tests; widget tests assert rendering against a pre-populated mirror

## Comments

### Implementer report

Built across two sessions. The first agent was cut off by a session limit with
everything still uncommitted — its work was backed up and a second agent verified
and landed it as `e5c82ba` and `6b5e41c`, then merged onto the phase branch.

**What the first agent built** — essentially the whole ticket, but unverified and
with one broken file:

- `GalleryGridController` — mirror-backed, item count fixed at `reload()`, sparse
  pages, so the grid does not shift under the user's thumb.
- `GalleryView` — responsive grid, floating month heading, drag scrubber.
- `GalleryPhotoViewerView` — `PageView` over the same list, thumbnail-behind-
  full-res, details sheet naming the Seraph folder.
- `GalleryTile`, `GalleryImageLoader` (plus a `CachedThumbnails` drift table at
  schema v3, so an offline gallery still shows thumbnails it has seen),
  `GalleryMediaUrls` over the existing `/preview` and `/dav/p` endpoints,
  `GalleryItemDisplay` (rotation, unsupported reasons, capture-date source).
- `queryItems`/`capturedAtAtOffset` on the mirror, plus routes and bindings.

**What the second agent fixed.** `gallery_image_loader_test.dart` did not
compile — it referenced an `exifOrientation6Jpeg` fixture and a `_resolve` helper
that were never written, so the entire file was silently skipped. A real 40×20
JPEG with EXIF Orientation 6 was generated, the fixture added, and the
`ImageProvider`→`ui.Image` helper written. The test now confirms Flutter's decoder
genuinely applies the orientation tag (decodes 20×40) — which the production
comment asserted and nobody had ever checked. Two tests added: opening the gallery
against a server that never answers (the "opens quickly after an update"
criterion), and a widget test for the Source Folders view.

**Ticket 14's Rescan action survived the `gallery_view` split intact**, and the
split improved it — a finished rescan now re-syncs the grid. It had no test
before; one was added asserting the action POSTs to
`/api/gallery/source-folders/{id}/rescan` rather than merely re-listing folders,
and that both the started and finished messages appear.

### Verifier verdict — APPROVED

Reviewed independently against `git diff dcc209b..HEAD` in the isolated worktree,
verifying the whole feature rather than trusting the unverified first pass.

- Grid and viewer read **exclusively from the local mirror** — no per-scroll
  network, item count fixed at `reload()`, pages sparse. The rejected two-cursor
  merge appears nowhere.
- Media comes from the **existing** `/preview` and `/dav/p` endpoints via Space
  paths, confirmed against `file_service.dart`. No new media endpoint.
- Upload and device controls are absent, asserted by the test *"the gallery offers
  nothing to upload with"*.
- Date headings, scrubber, unsupported placeholder with reason, folder shown in
  details, rotation (real EXIF-6 JPEG decode test), offline cached thumbnails and
  same-order swipe are all implemented and covered by tests that genuinely
  exercise the behaviour — several were spot-checked for triviality and would fail
  if the guarded behaviour were removed.
- **Rescan regression check passed:** `gallery_source_folders_view.dart` still
  calls `galleryService.rescanSourceFolder`, shows running state and polls to
  finished; the test asserts the POST hits the rescan endpoint, not a re-list.
- `gallery_mirror_database.g.dart` regenerated by `build_runner` is byte-identical
  to the committed file.
- **Checks:** `flutter test` 116/116 pass (baseline was 66), including
  `gallery_image_loader_test.dart` and `gallery_media_test.dart` confirmed to
  compile and run rather than being silently skipped; `flutter analyze` 45
  pre-existing issues, none in gallery files and none new; `flutter build web
  --release --base-href=/app/` succeeds.

### Decisions the ticket did not settle

- **Thumbnail bytes are cached in the mirror database** with a 2000-entry
  oldest-first budget. The spec lists cache eviction as an open question, though
  it raises it for full-resolution images rather than thumbnails. Worth revisiting
  when the full-res cache policy is decided.
- **Gallery Source Folder configuration moved off the gallery route** to
  `/gallery/folders`, behind an app-bar icon.
- **The requested thumbnail size is hardcoded to 512** to match the server's
  warmed size (ticket 11's `thumbnailer.warmSize` default). These two constants
  are now coupled across the client/server boundary with nothing enforcing it.

### Follow-up applied after approval

The verifier flagged, as a non-functional note, that `gallery_image_loader.dart`
embedded literal raw NUL bytes as a cache-key separator, which made git and
`file` treat the source as binary and left it permanently undiffable. Fixed
separately as a source-spelling change (`\x00` escape) with no behavioural effect.
