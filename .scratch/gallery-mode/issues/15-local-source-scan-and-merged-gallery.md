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

**Status:** ready-for-agent

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
