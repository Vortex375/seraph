---
status: accepted
date: 2026-11-01
---

# Capture Date is local wall time where the photo was taken, rendered via the stored offset

Gallery Mode orders photos by Capture Date, but EXIF `DateTimeOriginal` is a
zoneless wall-clock string that the gallery service parsed as UTC and the app
then rendered in the *device's* zone. A photo taken at 14:00 in Berlin in
summer showed as 16:00, and a device copy (MediaStore `DATE_TAKEN`, a true UTC
instant) disagreed with its cloud copy by the whole UTC offset — which also
made the mirror's size+Capture-Date dedup heuristic effectively never match
outside UTC.

## Decision

The gallery service stores Capture Date as a **true instant** (`capturedAt`,
Unix seconds, the sort key) plus, where the photo itself allows it, the **UTC
offset at the place of capture** (`capturedAtOffset`, seconds east of UTC,
null when unknown). Offset resolution for the EXIF rung, first hit wins:

1. EXIF `OffsetTimeOriginal` (tag `0x9011`, "±HH:MM") — the zone the camera
   clock was set to. goexif's field map predates EXIF 2.31 and drops unknown
   tags, so this one tag is read from the raw EXIF IFD with goexif's own TIFF
   parser.
2. The GPS timestamp: `GPSDateStamp` + `GPSTimeStamp` are UTC by definition,
   so the offset is wall time minus that instant, rounded to 15 minutes and
   accepted only within ±14 h.
3. None: the photo is *floating* — offset `0`, wall time stored as if UTC.

The `modTime` and `indexed` rungs are already true instants and carry a null
offset.

**Display rule, everywhere in the app:** wall time = `capturedAt +
capturedAtOffset`, rendered as UTC; when the offset is null, render
`capturedAt` in the device's local zone. One helper on `GalleryItemDisplay`
replaces `capturedAtDateTime`, and the scrubber's month-boundary map uses the
same helper, so the grid, the viewer and the scrubber can never disagree.

## Consequences

- The app's date-range filter, day labels and scrubber months are all computed
  in capture wall time (the mirror stores the offset alongside `capturedAt`).
- A device row and its cloud copy now agree whenever the server found an
  offset, and the size+Capture-Date dedup heuristic starts matching for photos
  whose offset is known. Floating photos still do not match outside UTC —
  accepted, the heuristic is best-effort.
- Deriving the offset from coordinates (timezone boundary data) for floating
  photos is deliberately out of scope: phones that write GPS usually also
  write `OffsetTimeOriginal` or a GPS timestamp. A `metadataVersion` bump
  would re-run them if that turns out to be common.
- Existing photos are corrected by the metadata sweep, not by this decision
  alone.
