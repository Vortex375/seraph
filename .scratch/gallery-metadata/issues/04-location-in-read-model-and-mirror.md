# 04 — Photo location and Place in the read model, feed and mirror

**What to build:** Wire GPS and Place resolution into the gallery service and carry it to the app's
mirror, per the spec ("Location extraction", "Read model and feed", "App mirror"):

- Extraction: `photoMetadata` gains `Lat`, `Lon *float64` from EXIF GPS (`goexif` `LatLong()`); `(0, 0)`
  and out-of-range values are treated as absent. Altitude and other GPS tags are not stored.
- Read model: `GalleryPhoto` gains `Lat`, `Lon`, `Place` (embedded document from ticket 02's
  `gallery/geo`), and `GeoVersion int`. Live ingestion resolves the Place and writes `geo.Version`.
- `MetadataVersion` is bumped so ticket 03's sweep extracts GPS for every existing photo.
- Sweep gains its second pass: photos at the current `metadataVersion` with coordinates but
  `geoVersion < geo.Version` are re-resolved from stored `Lat`/`Lon` without opening the file; `Seq` only
  bumps if the Place changed. Index on `geoVersion`.
- Feed: carries `lat`, `lon` and flattened Place fields (`placeCountryCode`, `placeCountry`,
  `placeAdmin1Code`, `placeAdmin1`, `placeLocalityId`, `placeLocality`).
- Mirror: next schema version adds `lat REAL`, `lon REAL`, and the six `place_*` text columns (all
  nullable), with indexes on `place_country_code`, `place_admin1_code`, `place_locality_id`. The delta
  model parses the new fields. Merging a cloud row into a device row copies location and Place.

No UI in this ticket.

**Blocked by:** 02, 03.

**Status:** ready-for-agent

- [ ] A fixture JPEG with GPS for a known city is stored with its coordinates and the expected Place.
- [ ] A fixture with GPS `(0, 0)` or no GPS is stored with no location and an empty Place.
- [ ] Existing photos gain location via the sweep after the `MetadataVersion` bump.
- [ ] Bumping `geo.Version` re-resolves stored coordinates without File Provider reads; unchanged Places
      do not bump `Seq`.
- [ ] The delta feed emits the new fields; the app's delta model parses them.
- [ ] Mirror migration from the previous version preserves rows with null location columns; a delta
      sync fills them.
- [ ] Merging a cloud row into a device row copies `lat`, `lon` and all `place_*` columns.
- [ ] Gates: `go test ./...` in `gallery`; `flutter analyze` zero issues;
      `flutter build web --release --base-href=/app/`.
