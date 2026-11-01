# 01 — Capture Date is local wall time where the photo was taken

**What to build:** Today the gallery service parses EXIF `DateTimeOriginal` (a zoneless wall-clock
string) as UTC (`gallery/gallery/metadata.go`, `exifCaptureDate`), and the app renders `capturedAt` in the
device's zone (`GalleryItemDisplay.capturedAtDateTime`). Photos show shifted by the UTC offset, and cloud
rows disagree with device rows, whose MediaStore `DATE_TAKEN` is a true instant.

This ticket implements the capture-time rule from the spec ("Capture time" under Implementation
Decisions), end to end:

- Server: `capturedAt` becomes a true instant whenever the offset is known; new `CapturedAtOffset *int`
  (seconds east of UTC) on `GalleryPhoto`. Offset for the EXIF rung: `OffsetTimeOriginal` (tag `0x9011`)
  → GPS timestamp (`GPSDateStamp`+`GPSTimeStamp`, offset = wall − GPS-UTC rounded to 15 min, accepted
  within ±14 h) → none (floating: wall time stored as UTC, offset `0`). `modTime`/`indexed` rungs: offset
  `nil`. If `goexif` cannot read `0x9011`, read that one tag from the raw IFD — no library switch.
- Feed: carries `capturedAtOffset`.
- App: mirror schema v14 adds `captured_at_offset INTEGER NULL`; delta model parses it. One display
  helper replaces `capturedAtDateTime`: wall time = `capturedAt + capturedAtOffset` rendered as UTC, or
  `capturedAt` in device-local zone when the offset is null. `capturedAtColumn` returns the offset too and
  the scrubber's month-boundary map uses the same helper. When a cloud row merges into a device row
  (`origin = both`), the merge writes the cloud row's `capturedAtOffset`; `capturedAt` stays untouched.
- Docs: ADR 0003 records the rule; `CONTEXT.md`'s **Capture Date** entry is updated.

Existing photos are corrected by the metadata sweep (ticket 03), not here.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] A fixture JPEG with `OffsetTimeOriginal = +02:00` and `DateTimeOriginal = 14:00` is stored with
      `capturedAt` = 12:00 UTC and `capturedAtOffset` = 7200.
- [ ] A fixture with GPS timestamp but no offset tag gets its offset from the GPS timestamp; a GPS
      timestamp implying more than ±14 h is ignored.
- [ ] A fixture with neither is stored floating: offset `0`, `capturedAt` = wall time as UTC.
- [ ] `modTime` and `indexed` rungs store offset `nil`.
- [ ] The delta feed emits `capturedAtOffset` (absent/null when `nil`).
- [ ] Mirror migration v13→v14 preserves existing rows with a null offset.
- [ ] Viewer label, grid day headers and scrubber months all use the single display helper; a test shows
      they agree for a photo at 23:30 wall time with offset +02:00 on a device in another zone.
- [ ] Merging a cloud row into a device row copies `capturedAtOffset` and does not change `capturedAt`.
- [ ] ADR 0003 and the `CONTEXT.md` update are written.
- [ ] Gates: `go test ./...` in `gallery`; `flutter analyze` zero issues;
      `flutter build web --release --base-href=/app/`.
