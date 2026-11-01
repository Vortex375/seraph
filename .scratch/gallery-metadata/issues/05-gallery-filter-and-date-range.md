# 05 — Gallery filter object and date-range filter

**What to build:** Today the mirror's read path takes only a `GalleryAvailabilityFilter`. This ticket
replaces it with one filter value object — Availability + optional date range + optional Place (Place
is used by ticket 06; this ticket only plumbs the field) — and ships the date-range filter, per the spec
("App mirror", "App UI"):

- The filter flows through `_visibilityPredicates(...).forFilter(...)` for `queryItems`, `totalCount` and
  `capturedAtColumn`, so grid, count and scrubber always agree.
- Date range is inclusive whole days in capture wall time: predicate on
  `captured_at + COALESCE(captured_at_offset, <device's current offset>)` against the day bounds.
  `ponytail:` comment on the single-device-offset shortcut (null-offset rows can be an hour off at a DST
  boundary; per-row handling if anyone notices).
- UI: a date-range action in the gallery app bar using `showDateRangePicker`; the active range shows as a
  removable chip above the grid. The Availability control is unchanged and combines with it.
- Clearing the filter returns to the full gallery the same way clearing the Availability filter does
  today.

**Blocked by:** 01 (needs `captured_at_offset` in the mirror).

**Status:** ready-for-agent

- [ ] A photo at 23:30 wall time (offset +02:00) on the range's last day is included; one at 00:30 the
      next day is not — independent of the device's zone.
- [ ] Null-offset rows are filtered by device-local wall time.
- [ ] Date range combines with each Availability value.
- [ ] Count and scrubber months reflect the filtered set.
- [ ] Removing the chip restores the unfiltered gallery.
- [ ] Existing Availability filter tests still pass against the new filter object.
- [ ] Gates: `flutter analyze` zero issues; `flutter test`;
      `flutter build web --release --base-href=/app/`.
