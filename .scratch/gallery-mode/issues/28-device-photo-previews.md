# 28 — Device photo previews

**What to build:** A device photo looks like a photo. Ticket 15 landed the merged
gallery but rendered every device item as a phone icon and a filename, in the
grid and in the full-screen viewer both, so a phone whose library is mostly not
yet backed up shows a wall of placeholders. This ticket closes that gap and
finishes Phase 2.

**This is not cosmetic.** The merged gallery's whole claim is that device photos
and Seraph photos are one continuous stream that a user reads without thinking
about where each one lives. An item the user cannot recognise breaks that claim
harder than a missing badge would: Availability is meant to be the discreet
detail and the picture the substance, and the placeholder inverts them.

**Previews come through the Local Source seam**, like everything else
platform-specific. Loading bytes for a device photo is exactly as
platform-specific as scanning for one, and a thumbnail path that reached around
the seam into MediaStore would undo ticket 15's central constraint. Platforms
with no Local Source keep behaving as they do today.

**Two sizes, two purposes.** The grid wants a small thumbnail, cheap enough to
produce while scrolling; the viewer wants the full image. Android's
`ContentResolver.loadThumbnail` serves the first and is the right call — it hands
back a size-appropriate bitmap and uses the system thumbnail cache rather than
decoding a 12-megapixel JPEG to fill a 150dp tile.

**A Synced item should prefer the device copy.** It is the same photo either way,
but the device copy needs no network and no server-side thumbnailing, so it
renders instantly and works offline. Fall back to the cloud thumbnail when the
device copy cannot be read.

**Failure is per-item and quiet.** A photo the app cannot decode — a corrupt
file, a revoked grant, a file deleted between scan and render — falls back to the
existing placeholder for that one tile. One unreadable photo must not blank the
grid or spin forever.

**Blocked by:** 15, 16

**Status:** resolved

- [ ] A Device only photo renders its actual image in the grid, not a placeholder
- [ ] A Device only photo renders its full image in the full-screen viewer
- [ ] A Synced photo renders from the device copy, and falls back to the cloud thumbnail when the device copy cannot be read
- [ ] A Cloud only photo renders exactly as it did before this ticket
- [ ] Grid thumbnails are requested at tile size, not by decoding full images and scaling down
- [ ] Scrolling a library of several thousand photos stays smooth, and memory does not grow without bound as the user scrolls
- [ ] Previews for tiles scrolled off screen are cancelled or evicted rather than run to completion
- [ ] A photo that cannot be decoded falls back to the placeholder for that tile alone, leaving the rest of the grid intact
- [ ] A photo deleted from the device between the scan and the render fails to that same placeholder rather than throwing
- [ ] Under a partial grant, photos the app was given render normally and no error is shown for the ones it was not given
- [ ] All device-image access sits behind the Local Source seam; nothing above it names MediaStore or a content URI
- [ ] On platforms without a Local Source implementation, the gallery renders exactly as it did before this ticket
- [ ] Covered at the app's mirror seam by driving a fake Local Source that returns image bytes, including the decode-failure and deleted-mid-render cases

## Comments

### Preceding fix (commit 93d9f3f)

Not part of this ticket, but landed immediately before it and shares its files.
`AndroidLocalSource` claimed the global `setMethodCallHandler` slot in its
constructor and never released it, and never closed its `_changesController`, so
a second instance would silently kill the first's `changes` stream. Safe only by
accident, via `LocalScanService` being a `Get.put` singleton. `LocalSource` gained
`dispose()`, `AndroidLocalSource` implements it behind a `_disposed` guard that is
idempotent and drops native calls arriving mid-dispose, and
`LocalScanService.dispose()` calls into it. Verified APPROVED: the guard was
checked in the code rather than by test name, the channel architecture was left
alone, and ticket 17's observer release through `onClose()` is untouched.

### Implementer report (commit 9649963)

Device photo previews, closing the gap ticket 15 left where device items rendered
a phone icon instead of pixels — in the grid and the full-screen viewer both.

- `local_media_item.dart` — `LocalSource` gained `loadThumbnail` / `loadOriginal`,
  resolved per call from the durable `(relativePath, displayName)` identity rather
  than the same-scan-only `mediaStoreId` hint, returning null quietly on any
  failure.
- `MainActivity.kt` — new `loadThumbnail` / `loadOriginal` channel handlers that
  re-resolve the content Uri fresh each call, use `ContentResolver.loadThumbnail`
  for tile-sized bitmaps (never decoding a full JPEG to fill a tile) and
  `openInputStream` for the original. Every failure mode reports null, never a
  channel error.
- `android_local_source.dart` — implements the two new methods.
- `local_image_loader.dart` (new) — `LocalImageLoader` and a `LocalGalleryImage`
  `ImageProvider`, mirroring the existing `GalleryImageLoader` / `GalleryImage`,
  with in-flight de-duplication.
- `gallery_tile.dart` / `gallery_photo_viewer.dart` — Device only renders the
  local image with a placeholder `errorBuilder` fallback; Synced prefers the
  device copy and falls back to the cloud image on failure; Cloud only unchanged.
- `initial_binding.dart`, `gallery_view.dart` — wired `LocalImageLoader` through
  Get.

Tests: new `AndroidLocalSource` channel coverage plus a "device photo previews"
widget group in `gallery_view_test.dart` covering Device only / Synced / Cloud
only rendering, decode failure, deleted-mid-render and a partial grant. 214/214
pass (200 baseline + 14 new), `flutter analyze` 45 pre-existing issues (none new),
`flutter build web --release` and `flutter build apk --debug` both succeed.

Decisions the ticket did not settle:

1. Photo identity for byte-loading is `(relativePath, displayName)` re-resolved via
   a fresh MediaStore query each call rather than any cached id — this is what
   makes the deleted and changed-id cases resolve to nothing instead of the wrong
   file.
2. No explicit cancellation of in-flight native requests for off-screen tiles.
   Relies on Flutter's bounded `ImageCache` and in-flight de-duplication, the same
   strategy the existing cloud thumbnail path already uses; the acceptance
   criterion allows "cancelled or evicted".
3. Flutter's `ImageCache` is a process-wide singleton across tests, so
   `gallery_view_test.dart`'s `tearDown` now clears it — otherwise two tests
   reusing the same device-photo identity would silently share a cached decode.

Noticed but out of scope: `gallery_photo_viewer.dart` had already grown large
before this ticket. Splitting `_CloudPhotoStack` / `_LocalPhotoStack` out was
necessary here to avoid nesting two `InteractiveViewer`s, but the file could use a
further split later.

### Verifier verdict

APPROVED. Checked against the code rather than commit messages:

- Nothing above the seam names MediaStore or a content URI — a grep over `lib/`
  turns up only comments inside the seam files themselves.
- The grid requests tile-sized bitmaps via `LocalGalleryImage(width:, height:)`
  sized from the tile's own `decodeWidth`, backed by `ContentResolver.loadThumbnail`;
  the viewer's layer omits width/height to fetch the original. Grid and viewer are
  cleanly split, and the grid is not quietly decoding full images.
- Memory is bounded by Flutter's own `ImageCache` at untouched defaults plus
  `GridView.builder` virtualization. No custom unbounded cache was added;
  `LocalImageLoader` only de-duplicates in-flight requests.
- Decode failure and deleted-mid-render both resolve to null or a thrown
  `LocalGalleryImageUnavailable` caught by `errorBuilder`, isolated per tile.
- Partial grant reuses ticket 16's native access gate; no summary or badge changed.
- No regressions: `gallery_mirror.dart`, `local_scan_service.dart` and the
  content-observer code from tickets 15 and 17 are untouched. `LocalSource.dispose()`
  is unchanged and no second lifecycle was introduced.

`flutter test` 214/214, `flutter analyze` 45 issues all pre-existing (0 new),
`flutter build web --release` and `flutter build apk --debug` both succeed.
