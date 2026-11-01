# 06 — Place search, place filter and location in the viewer

**What to build:** The user-facing half of location, per the spec ("App mirror", "App UI"):

- Place filter: the filter object's Place (one of country / admin1 / locality, by id) becomes a predicate
  on `place_country_code`, `place_admin1_code` or `place_locality_id`. Photos without a Place never match
  it.
- Suggestions: `GROUP BY` over the mirror per level, filtered by case-insensitive substring of the typed
  text, ordered by photo count, under the same Local Folder visibility as the grid. Regions and cities
  show their parent ("Bavaria, Germany").
- UI: a search action in the gallery app bar opens a field with grouped suggestions (Countries, Regions,
  Cities, each with a count). Picking one sets the Place filter and shows a removable chip; it combines
  with the date range and Availability.
- Viewer: the details sheet adds a location line — locality, admin1, country, skipping empty parts. No
  coordinates, no map.

**Blocked by:** 04, 05.

**Status:** ready-for-agent

- [ ] Typing "por" suggests Portugal (and e.g. Porto) with counts drawn only from the user's visible
      photos.
- [ ] Picking a country / region / city shows exactly the photos with that Place id; count and scrubber
      match.
- [ ] Place + date range + Availability combine.
- [ ] Photos in an unselected Local Folder do not appear in suggestions or counts.
- [ ] The viewer shows "Lisbon, Lisbon, Portugal" for a photo with that Place and no location line for a
      photo without one.
- [ ] Gates: `flutter analyze` zero issues; `flutter test`;
      `flutter build web --release --base-href=/app/`.
