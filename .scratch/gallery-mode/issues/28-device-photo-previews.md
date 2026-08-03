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

**Status:** ready-for-agent

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
