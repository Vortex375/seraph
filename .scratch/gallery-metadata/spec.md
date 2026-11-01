# Gallery metadata: capture time, location and search

Status: ready-for-agent

Phase: specification. Decided in conversation on 2026-11-01. Tickets in `issues/`.

## Problem Statement

Gallery Mode orders photos by Capture Date, but there is no way to find a
photo: no date-range filter and nothing about *where* a photo was taken. The
photos themselves usually know — phones write GPS coordinates into EXIF — and
Seraph throws that away.

Two further defects sit under this:

- **Capture Date is shifted by the timezone.** EXIF `DateTimeOriginal` is a
  wall-clock time with no zone. `gallery/gallery/metadata.go`
  (`exifCaptureDate`) parses it as UTC, and the app renders it with
  `DateTime.fromMillisecondsSinceEpoch` in the *device's* zone
  (`GalleryItemDisplay.capturedAtDateTime`). A photo taken at 14:00 in Berlin
  in summer shows as 16:00. Device rows, by contrast, carry MediaStore
  `DATE_TAKEN`, a true UTC instant — so a device copy and its cloud copy
  disagree by the UTC offset. The mirror's size+Capture-Date heuristic
  (`gallery_mirror.dart`, "Rule 3" and the uncovered-device-item path) uses
  exact `capturedAt` equality, so outside UTC it effectively never matches.
  Any day-based date filter built on today's values would be off around
  midnight.
- **Backfilled photos never get metadata.** `MetadataPending` documents stay
  pending until a live event touches the path again; nothing re-extracts
  them. Neither does anything re-extract existing photos when extraction
  learns a new field — which this feature needs for every existing photo.

## Solution

1. **Capture time means local wall time where the photo was taken.** The
   gallery service stores Capture Date as a true UTC instant plus, where it
   can be determined, the UTC offset at the place of capture. The app renders
   day labels, scrubber months and date filters in that wall time.
2. **The gallery service reads GPS from EXIF and resolves it to a Place**
   (city, region, country, in English) entirely offline, against an embedded
   dataset built from GeoNames and Natural Earth. No external service, no
   network at runtime.
3. **A metadata sweep** in the gallery service re-extracts every photo whose
   stored metadata is older than the current extraction version — including
   all `MetadataPending` documents — and re-resolves Places from stored
   coordinates when the dataset changes.
4. **Location and offset travel through the existing delta feed** into the
   app's mirror as new columns.
5. **The app filters the mirror** by date range and by Place, combined with
   the existing Availability filter, and keeps the scrubber, counts and
   ordering working under the filter. Place suggestions come from the places
   that occur in the user's own photos.
6. **The photo viewer shows the Place name** of a photo.

Device-only photos get location once they are uploaded; the device does not
read GPS itself.

## User Stories

1. As a user, I see the time a photo was taken as the clock showed it where I
   took it, regardless of where my phone is now.
2. As a user, the device copy and the Seraph copy of a photo show the same
   date and time.
3. As a user, I can restrict the gallery to a date range and see only photos
   captured on those days (inclusive, in capture wall time).
4. As a user, I can type a place name and pick a country, region or city from
   suggestions drawn from my own photos, each with a photo count.
5. As a user, picking a country shows all my photos taken in that country;
   picking a region or city narrows accordingly.
6. As a user, I can combine a place, a date range and the Availability filter.
7. As a user, the date scrubber and the item count reflect the filtered set.
8. As a user, I can clear the filters and return to the full gallery at the
   same scroll position semantics as today's Availability filter.
9. As a user, the photo viewer's details show where a photo was taken
   ("Lisbon, Lisbon, Portugal"), never raw coordinates.
10. As a user, photos without GPS still appear in unfiltered and date-filtered
    views; they are simply not matched by a place filter.
11. As a user, photos already in Seraph before this feature gain location and
    a corrected time without me doing anything.
12. As a user, a photo taken at sea or in a remote area still shows its
    country when it is plainly inside one, and no city when no city is near.
13. As the operator, the feature needs no API key, no extra container and no
    outbound network access.

## Implementation Decisions

### Capture time

- `GalleryPhoto.CapturedAt` stays Unix seconds and stays the sort key, but
  becomes a **true instant** whenever the offset is known.
- New field `CapturedAtOffset *int` (seconds east of UTC, `nil` = not set).
  Display rule, everywhere in the app: **wall time = `capturedAt` +
  `capturedAtOffset`, rendered as UTC; when the offset is null, render
  `capturedAt` in the device's local zone.** One helper on
  `GalleryItemDisplay` replaces `capturedAtDateTime`; the scrubber's
  month-boundary map (`capturedAtColumn` → controller) must use the same
  helper, so it reads the offset column alongside `capturedAt`.
- Offset resolution for the EXIF rung, first hit wins:
  1. EXIF `OffsetTimeOriginal` (tag `0x9011`, string `±HH:MM`).
  2. GPS timestamp: `GPSDateStamp` + `GPSTimeStamp` are UTC; offset =
     wall − GPS-UTC, rounded to 15 minutes, accepted only within ±14 h.
  3. None: the wall time is stored as if it were UTC with offset `0`
     ("floating"), which renders the wall clock unchanged under the display
     rule.
- The `modTime` and `indexed` rungs are already true instants: offset `nil`.
- `goexif` (2019) may not expose `OffsetTimeOriginal` — its field map
  predates EXIF 2.31. Check first; if it cannot read it, read that one tag
  from the raw EXIF IFD ourselves rather than switching libraries. GPS tags
  `goexif` does support (`LatLong()`, `GPSDateStamp`, `GPSTimeStamp`).
- Device rows keep `DATE_TAKEN` (true instant) with offset `nil`. When a
  cloud row merges into a device row (`origin = both`), the merge writes the
  cloud row's `capturedAtOffset` and location columns; `capturedAt` stays
  untouched as today (it must not move the row). After the fix both sides
  hold true instants, so they agree whenever the server found an offset.
- The size+`capturedAt` heuristic is not changed by this spec; it simply
  starts matching for photos whose offset is known. Floating photos still
  won't match outside UTC — accepted, as the heuristic is best-effort today.
- Write ADR 0003 recording the rule, and update **Capture Date** in
  `CONTEXT.md`.

### Location extraction

- `photoMetadata` gains `Lat`, `Lon *float64` (WGS84). `(0, 0)` and values
  outside ±90/±180 are treated as absent — some cameras write zeros.
- Altitude, direction and other GPS tags are not stored.

### Place resolution (`gallery/geo` package)

- In-process package in the gallery module. No separate service: the gallery
  service is the only consumer.
- A **Place** is: `countryCode` (ISO-3166 alpha-2), `country`, `admin1Code`
  (GeoNames form `CC.code`, e.g. `DE.02`), `admin1`, `localityId` (GeoNames
  id), `locality`. All names English. Any part may be empty.
- Resolution of `(lat, lon)`:
  1. Country by point-in-polygon against Natural Earth admin-0 (1:50m).
     If no polygon contains the point (coastline is coarse at 1:50m), use the
     nearest locality's country when that locality is within 25 km.
  2. Locality: the nearest GeoNames populated place **in that country**
     within 50 km; otherwise none. Region comes from that locality's admin1.
     With no country, the nearest place globally within 50 km.
- Lookup structure: a 1°×1° grid of buckets over the locality list, searching
  the cell and its neighbours. Point-in-polygon: ray casting with a
  bounding-box pre-check. No geo library.
- **Dataset is generated and committed**, like the repo's other codegen:
  `gallery/geo/Makefile` downloads GeoNames `cities500`,
  `admin1CodesASCII.txt`, `countryInfo.txt`, the English preferred names from
  `alternateNamesV2` (falling back to the GeoNames `name`, which is not
  reliably English), and Natural Earth `ne_50m_admin_0_countries`, and writes
  one compact gzipped file embedded with `go:embed`. Budget: ≤ 6 MB
  compressed in git; if `cities500` blows it, use `cities1000`. Regeneration
  is manual, never at build or run time — reproducible builds, no network,
  testable fixtures.
- Attribution: GeoNames is CC-BY 4.0 — add credit in the README and an
  about/licences surface where one exists. Natural Earth is public domain.
- `geo.Version` is a constant bumped whenever the dataset or resolution logic
  changes.

### Read model and feed

- `GalleryPhoto` gains `CapturedAtOffset`, `Lat`, `Lon`, `Place` (embedded
  document), `MetadataVersion int`, `GeoVersion int`.
- Delta feed JSON carries `capturedAtOffset`, `lat`, `lon` and the flattened
  Place fields. `MetadataVersion`/`GeoVersion` are server-internal.
- No `2dsphere` index: filtering happens in the mirror.

### Metadata sweep

- A background loop in the gallery service, started on boot, that pages
  through non-deleted photos with `metadataVersion < current` (oldest `_id`
  first), opens each through the File Provider exactly as live ingestion does
  (`extractForEvent`), re-runs extraction and place resolution, and upserts.
  This also clears `MetadataPending`.
- A second, cheaper pass: photos at the current `metadataVersion` but
  `geoVersion < geo.Version` with coordinates are re-resolved from stored
  `Lat`/`Lon` without opening the file.
- `Seq` is bumped only when a field the feed carries actually changed, so a
  dataset bump that changes nothing does not resync every mirror.
- Concurrency 1, with a short pause between pages; state lives on the
  documents, so a restart resumes for free. A file that cannot be opened
  (gone, provider offline) keeps its old version and is retried on the next
  boot — it must not block the sweep.
- Live ingestion writes the current versions, so new photos never enter the
  sweep.
- Needs an index on `metadataVersion` (and `geoVersion`) — new migration.

### App mirror

- Drift schema v14: `captured_at_offset INTEGER NULL`, `lat REAL NULL`,
  `lon REAL NULL`, `place_country_code`, `place_country`,
  `place_admin1_code`, `place_admin1`, `place_locality_id`,
  `place_locality` (text, nullable). Indexes on `place_country_code`,
  `place_admin1_code`, `place_locality_id`.
- Existing rows get nulls; the server sweep bumps their `Seq`, so the normal
  delta sync fills them in. No client-side backfill.
- The filter becomes one value object: Availability + optional date range +
  optional Place (one of country / admin1 / locality, by id). It flows
  through the existing `_visibilityPredicates(...).forFilter(...)` path used
  by `queryItems`, `totalCount` and `capturedAtColumn`.
- Date range predicate: convert the inclusive day range to wall-time bounds
  and compare against `captured_at + COALESCE(captured_at_offset, <device
  offset>)`. ponytail: a single device offset (the current one) for
  null-offset rows instead of per-instant DST — only those rows can be off by
  an hour at a DST boundary; per-row handling if anyone notices.
- Place suggestions: `GROUP BY` over the mirror for each level, filtered by
  case-insensitive substring of the typed text, ordered by count, under the
  same Local Folder visibility as the grid.

### App UI

- A search action in the gallery app bar opens a field with grouped
  suggestions (Countries, Regions, Cities, each with counts). Region and city
  suggestions show their parent ("Bavaria, Germany").
- A date-range action uses Flutter's `showDateRangePicker`.
- Active filters show as removable chips above the grid; the Availability
  filter keeps its current control.
- The viewer's details sheet adds a location line: locality, admin1, country
  (empty parts skipped). No map.

## Testing Decisions

- **Go unit tests** (`gallery/gallery`): offset resolution from fixture
  JPEGs — `OffsetTimeOriginal`, GPS-timestamp-only, neither. GPS extraction
  including the `(0,0)` case. Extend `exif_fixture_test.go`'s fixtures.
- **Go unit tests** (`gallery/geo`): resolution against the real embedded
  dataset for a fixed list of known points — a city centre, a border town
  (e.g. Basel area, Strasbourg/Kehl), a coastal point outside the 1:50m
  polygon, open ocean, a remote mountain point with no locality in 50 km.
- **Go integration tests**: the sweep re-extracts a pre-existing photo at an
  old version, clears `MetadataPending`, bumps `Seq` once; an unchanged
  re-resolution does not bump `Seq`; an unreadable file does not stall the
  sweep. Follow `backfill_integration_test.go`'s setup.
- **Dart tests**: mirror migration v13→v14; delta model parses the new
  fields; filter predicates (date range across midnight with offsets, place
  levels, combination with Availability); `capturedAtColumn` and the display
  helper agree on day/month boundaries; merge of a cloud row into a device row
  copies offset and Place.
- **Gates**: `go test ./...` in `gallery`; `flutter analyze` with zero
  issues; `flutter build web --release --base-href=/app/`; no `android/`
  changes are expected — if any appear, `flutter build apk` too.

## Out of Scope

- HEIC (and RAW): still `Unsupported`, so no date or location from them.
- Reading GPS on the device; device-only photos get location when uploaded.
- Searching places that do not occur in the user's photos; "near X within
  N km"; polygon-exact region boundaries (admin1 comes from the nearest
  locality).
- Map view and map tiles.
- Non-English place names.
- Street / neighbourhood / POI detail.
- Deriving the offset from coordinates (timezone boundary data) for floating
  photos. Phones that write GPS usually also write `OffsetTimeOriginal` or a
  GPS timestamp; revisit if floating photos turn out common. A
  `metadataVersion` bump would re-run them.
- Editing a photo's date or location.
- Stripping location from shared files.

## Further Notes

- `CONTEXT.md` gains **Place** (the city/region/country a photo was taken in,
  resolved offline from its coordinates; _Avoid_: location, address, geotag)
  and an updated **Capture Date** reflecting the wall-time rule.
- The web app (Angular) is unaffected; Gallery Mode lives in the Flutter app,
  and everything here runs wherever the mirror runs.
- Tickets live in `issues/`. 01 (capture time) and 02 (`gallery/geo`) start
  immediately; 03 (sweep) and 05 (filter + date range) follow 01; 04
  (location end to end) needs 02 and 03; 06 (place search + viewer) needs 04
  and 05.
