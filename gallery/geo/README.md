# gallery/geo

Offline place resolution for gallery photos: `(lat, lon)` → country, region
(admin-1) and locality (city/town), in English. Pure, in-process, no network
access, no API key, no extra container.

## Dataset

The dataset (`data/geodata.bin.gz`) is **generated and committed** - like the
repo's other codegen, regeneration is manual (`make` in this directory), never
at build or run time. The binary layout is documented by
`dataset.go` (`decodeDataset`) and produced by `cmd/generate`.

The generation budget is ≤ 6 MB compressed in git; if `cities500` overflows it,
regenerate from `cities1000` instead (Makefile + generator take a `-cities`
argument).

## Sources and licences

- **GeoNames** (<https://www.geonames.org>) - `cities500`,
  `admin1CodesASCII.txt`, `countryInfo.txt` and the English preferred names
  extracted from `alternateNamesV2`. Licenced under
  **Creative Commons Attribution 4.0 (CC-BY 4.0)**:
  <https://creativecommons.org/licenses/by/4.0/>
- **Natural Earth** (<https://www.naturalearthdata.com>) -
  `ne_50m_admin_0_countries` (1:50m admin-0 boundaries), used for
  point-in-polygon country resolution. **Public domain.**

Any surface in the product that presents resolved place names should carry the
GeoNames credit ("Place data © GeoNames, CC-BY 4.0") alongside other licences.
