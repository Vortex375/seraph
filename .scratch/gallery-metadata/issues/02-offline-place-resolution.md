# 02 — Offline place resolution package and dataset

**What to build:** A new `gallery/geo` package that resolves `(lat, lon)` to a **Place** — `countryCode`,
`country`, `admin1Code` (GeoNames `CC.code`), `admin1`, `localityId` (GeoNames id), `locality`, all in
English, any part possibly empty — entirely offline. It is a pure package: nothing in the gallery
service calls it yet (ticket 04 wires it in).

Per the spec ("Place resolution"):

- Country by point-in-polygon against Natural Earth admin-0 1:50m; if no polygon contains the point, the
  nearest locality's country when that locality is within 25 km.
- Locality: nearest GeoNames populated place in that country within 50 km, else none; region from that
  locality's admin1. With no country: nearest place globally within 50 km.
- Lookup: 1°×1° grid buckets (cell + neighbours, handling the antimeridian and poles); ray casting with a
  bounding-box pre-check. No geo library.
- Dataset: `gallery/geo/Makefile` downloads GeoNames `cities500`, `admin1CodesASCII.txt`,
  `countryInfo.txt`, English preferred names from `alternateNamesV2` (fallback: GeoNames `name`), and
  Natural Earth `ne_50m_admin_0_countries`, and writes one gzipped file embedded via `go:embed`.
  Committed; never downloaded at build or run time. Budget ≤ 6 MB compressed — fall back to
  `cities1000` if exceeded.
- `geo.Version` constant, bumped whenever the dataset or resolution logic changes.
- GeoNames CC-BY 4.0 attribution added to the README.

The data is loaded once (lazily or at service start) and is safe for concurrent lookups.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] `make` in `gallery/geo` regenerates the embedded file reproducibly from the downloaded sources;
      the generated file is committed and within budget.
- [ ] Known points resolve as expected against the real dataset: a city centre (e.g. Lisbon → Lisbon,
      Lisbon, Portugal); border points on both sides (e.g. Strasbourg → France, Kehl → Germany; a point in
      Basel → Switzerland); a coastal point outside the 1:50m polygon still gets its country; open ocean
      → empty Place; a remote point with no locality within 50 km → country only.
- [ ] Names are English where GeoNames has an English preferred name (e.g. Munich, not München).
- [ ] Lookups are concurrency-safe (test under `-race`).
- [ ] A lookup costs well under 1 ms on a dev machine (benchmark, not a hard gate).
- [ ] README credits GeoNames (CC-BY 4.0) and Natural Earth.
- [ ] Gates: `go test ./...` in `gallery`.
