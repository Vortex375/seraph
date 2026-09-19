# 15 — Local Source seam, media-store scan and the merged gallery

**What to build:** **Phase 2 ships here.** On Android, Gallery Mode shows photos
on the phone and photos in Seraph as one continuous stream ordered by Capture
Date. A photo that exists in both places appears exactly once. Each Gallery Item
carries an Availability — *Device only*, *Synced* or *Cloud only* — shown
discreetly on the tile and filterable, but never fragmenting the ordering.

Device photos are imported into the **same table** as cloud items, so dedup
happens at write time and the merged view stays a single indexed query.

**The Local Source seam is a design constraint, not an abstraction for its own
sake.** A Sync Pair's local side is an opaque **Local Source** identifier, not a
hardcoded directory path, and "relative path within the source" is a value the
platform-specific local-media layer produces — from the real path on Android,
later from album plus original filename on iOS. Everything above this seam is
platform-neutral. Designing without it would force the date-derived remote
layout that the design explicitly rejected.

**The full media-store scan is the correctness anchor.** One projection-only
cursor over id, date taken, date modified, size, relative path and display name;
sub-second for 10,000 images. It runs at app start and periodically. Faster
incremental detection comes later and is purely a latency improvement.

**Local identity is `(relative path, display name, size, date taken)`**, with the
media-store row id as a hint only. The id is not durable: a file deleted and
recreated, moved between folders, or restored by another app gets a new row, and
keying on it would treat the photo as new.

**Blocked by:** 13

**Status:** resolved

- [ ] Photos on the device appear in the gallery interleaved with photos from Seraph, in Capture Date order
- [ ] A photo present both on the device and in Seraph appears exactly once
- [ ] Every item shows exactly one Availability: Device only, Synced or Cloud only
- [ ] Availability is shown discreetly on the tile and does not affect ordering
- [ ] The gallery can be filtered to items that are not backed up, and to Cloud only items
- [ ] A summary shows how many photos are backed up and how many are not
- [ ] A device photo keeps the same position in the timeline whether it is Device only or Synced
- [ ] Local identity is `(relative path, display name, size, date taken)`; a photo whose media-store id changed is not treated as a new photo
- [ ] A full scan of 10,000 photos completes quickly enough to run at app start without a visible delay
- [ ] All device-media access sits behind the Local Source seam, and everything above it is platform-neutral
- [ ] On platforms without a Local Source implementation, the gallery behaves exactly as it did before this ticket
- [ ] Covered at the app's mirror seam with a fake Local Source, including dedup between a device item and a cloud item for the same photo

## Comments

### Implementer report (commit 498a304)

Built the Local Source seam, MediaStore scan and merged gallery.

- `lib/src/gallery/local/` — platform-neutral `LocalSource`/`LocalMediaItem` seam,
  `AndroidLocalSource` (method channel `seraph/local_media`), conditional-import
  platform selection (Android gets a real source; everything else, including
  tests, gets null), mirroring the existing `mirror/connection/` pattern.
- `android/.../MainActivity.kt` — the single projection-only MediaStore cursor
  (id, date taken, date modified, size, relative path, display name), normalizing
  MediaStore's date-unit inconsistency before crossing the channel.
  `AndroidManifest.xml` gained `READ_MEDIA_IMAGES`.
- `gallery_mirror.dart` — `applyLocalScan` merges a full scan into `GalleryItems`:
  exact local-identity match is a no-op (handles a changed media-store id);
  cross-source dedup by `(size, capturedAt)` runs from both the scan side and
  `applyPage`, so order of arrival never produces two rows; a cloud tombstone on a
  Synced row demotes rather than deletes it, and vice versa for a vanished device
  file. Added `GalleryAvailabilityFilter`, `GalleryAvailabilitySummary` and
  filter-aware query methods.
- `gallery_item_display.dart`, `gallery_tile.dart`, `gallery_photo_viewer.dart`,
  `gallery_view.dart` — `GalleryAvailability` extension, discreet tile badge,
  filter menu, backed-up/not-backed-up summary bar; fixed a hardcoded "Cloud only"
  label left over from ticket 13.
- `gallery_grid_controller.dart` / `initial_binding.dart` — wires
  `LocalScanService` alongside the existing cloud sync, isolating failures between
  the two.

Tests: new mirror-seam coverage (`gallery_local_scan_test.dart`,
`local_scan_service_test.dart` with a fake `LocalSource`,
`android_local_source_test.dart` at the channel boundary) plus controller
filter/summary/failure-isolation tests. `flutter test` 137/137, `flutter analyze`
45 pre-existing issues (none new), `flutter build web --release` and
`flutter build apk --debug` both succeed.

Decisions the ticket did not settle:

1. Device/cloud dedup heuristic is `(size, capturedAt)` — no Sync Pair exists yet
   to link a device path to a remote path, and the spec's "no content hashing"
   rule left nothing stronger to match on.
2. Device-only tiles and the full-screen viewer render an honest placeholder
   (phone icon + filename) rather than a live thumbnail — no acceptance criterion
   asked for pixel rendering, and it would have required a second native
   content-resolver path. Noted for a follow-up.
3. Permission handling is minimal by design: the native side checks the grant and
   returns empty rather than throwing if absent — no request UI, since that is
   ticket 16.

### Verifier verdict

APPROVED — diff checked against every acceptance criterion; tests, analyze, web
build and Android debug build all run against commit 498a304.
