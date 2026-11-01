// Copyright © 2024 Benjamin Schmitz

// This file is part of Seraph <https://github.com/Vortex375/seraph>.

// Seraph is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License
// as published by the Free Software Foundation,
// either version 3 of the License, or (at your option)
// any later version.

// Seraph is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.

// You should have received a copy of the GNU Affero General Public License
// along with Seraph.  If not, see <http://www.gnu.org/licenses/>.

package geo

import (
	"bytes"
	"compress/gzip"
	"embed"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
)

//go:embed data/geodata.bin.gz
var datasetFS embed.FS

var datasetBytes = mustDatasetBytes()

func mustDatasetBytes() []byte {
	b, err := datasetFS.ReadFile("data/geodata.bin.gz")
	if err != nil {
		// the file is embedded at build time; a build that lacks it cannot
		// have compiled this package at all
		panic("geo: embedded dataset missing: " + err.Error())
	}
	return b
}

// datasetFormatVersion is the binary dataset's layout version. Bump it
// whenever the encoding changes; geo.Version (the semantic version the
// service stores per photo) bumps alongside every dataset regeneration,
// layout change or not.
const datasetFormatVersion = 1

// coordScale is the fixed-point scale coordinates are stored at: 1e-5
// degrees is roughly one metre, far finer than any decision this package
// makes, and half the size of a float64.
const coordScale = 100000

const (
	earthRadiusKm = 6371.0088
	kmPerDegree   = 111.32
)

// ---------- decoded structures ----------

type geoPoint struct {
	lat, lon float64
}

type bbox struct {
	minLat, maxLat, minLon, maxLon float64
}

func (b bbox) contains(lat, lon float64) bool {
	return lat >= b.minLat && lat <= b.maxLat && lon >= b.minLon && lon <= b.maxLon
}

type ring struct {
	pts  []geoPoint
	hole bool
	bbox bbox
}

type polygon struct {
	rings []ring
	bbox  bbox
}

type country struct {
	code  string
	name  string
	polys []polygon
	bbox  bbox
}

type locality struct {
	id     int64
	lat    float64
	lon    float64
	cc     string
	admin1 string
	name   string
}

// dataset is the fully decoded, indexed dataset. Built once and then
// strictly read-only, so concurrent Resolve calls need no locking (see
// Resolve's doc).
type dataset struct {
	countries   []country
	admin1Names map[string]string // "CC.code" -> English name
	localities  []locality
	grid        map[int32]map[int32][]int32 // 1° cell -> indexes into localities
}

// buildIndex buckets every locality into 1°x1° cells. Done once, at load;
// lookups then touch only a handful of cells.
func (d *dataset) buildIndex() {
	d.grid = make(map[int32]map[int32][]int32)
	for i := range d.localities {
		l := &d.localities[i]
		x, y := cellOf(l.lat, l.lon)
		m, ok := d.grid[y]
		if !ok {
			m = make(map[int32][]int32)
			d.grid[y] = m
		}
		m[x] = append(m[x], int32(i))
	}
}

func cellOf(lat, lon float64) (int32, int32) {
	return int32(math.Floor(lon)), int32(math.Floor(lat))
}

// ---------- decoding ----------

// decodeDataset decodes the binary format the generator (cmd/generate)
// writes, from gzipped bytes.
func decodeDataset(gz []byte) (*dataset, error) {
	zr, err := gzip.NewReader(bytes.NewReader(gz))
	if err != nil {
		return nil, fmt.Errorf("geo: dataset gzip: %w", err)
	}
	defer zr.Close()
	raw, err := io.ReadAll(zr)
	if err != nil {
		return nil, fmt.Errorf("geo: dataset read: %w", err)
	}

	d := &dataset{admin1Names: make(map[string]string)}
	r := &datasetReader{buf: raw}

	if err := r.expectMagic(); err != nil {
		return nil, err
	}
	format, err := r.u8()
	if err != nil {
		return nil, err
	}
	if format != datasetFormatVersion {
		return nil, fmt.Errorf("geo: dataset format version %d, want %d", format, datasetFormatVersion)
	}

	if d.countries, err = r.decodeCountries(); err != nil {
		return nil, err
	}
	if d.admin1Names, err = r.decodeAdmin1(); err != nil {
		return nil, err
	}
	if d.localities, err = r.decodeLocalities(); err != nil {
		return nil, err
	}
	return d, nil
}

type datasetReader struct {
	buf []byte
	pos int
}

func (r *datasetReader) remaining() int { return len(r.buf) - r.pos }

func (r *datasetReader) byteAt() (byte, error) {
	if r.remaining() < 1 {
		return 0, io.ErrUnexpectedEOF
	}
	b := r.buf[r.pos]
	r.pos++
	return b, nil
}

func (r *datasetReader) u8() (uint8, error) {
	b, err := r.byteAt()
	return uint8(b), err
}

func (r *datasetReader) u32() (uint32, error) {
	if r.remaining() < 4 {
		return 0, io.ErrUnexpectedEOF
	}
	v := binary.LittleEndian.Uint32(r.buf[r.pos:])
	r.pos += 4
	return v, nil
}

func (r *datasetReader) i32() (int32, error) {
	v, err := r.u32()
	return int32(v), err
}

func (r *datasetReader) string() (string, error) {
	n, err := r.u16len()
	if err != nil {
		return "", err
	}
	if r.remaining() < int(n) {
		return "", io.ErrUnexpectedEOF
	}
	s := string(r.buf[r.pos : r.pos+int(n)])
	r.pos += int(n)
	return s, nil
}

func (r *datasetReader) u16len() (int, error) {
	if r.remaining() < 2 {
		return 0, io.ErrUnexpectedEOF
	}
	n := binary.LittleEndian.Uint16(r.buf[r.pos:])
	r.pos += 2
	return int(n), nil
}

func (r *datasetReader) raw(n int) ([]byte, error) {
	if r.remaining() < n {
		return nil, io.ErrUnexpectedEOF
	}
	b := r.buf[r.pos : r.pos+n]
	r.pos += n
	return b, nil
}

func (r *datasetReader) expectMagic() error {
	b, err := r.raw(4)
	if err != nil {
		return err
	}
	if string(b) != "SGEO" {
		return errors.New("geo: dataset magic mismatch")
	}
	return nil
}

func (r *datasetReader) decodeCountries() ([]country, error) {
	n, err := r.u32()
	if err != nil {
		return nil, err
	}
	countries := make([]country, 0, n)
	for i := uint32(0); i < n; i++ {
		codeBytes, err := r.raw(2)
		if err != nil {
			return nil, err
		}
		name, err := r.string()
		if err != nil {
			return nil, err
		}
		polyCount, err := r.u32()
		if err != nil {
			return nil, err
		}
		c := country{code: string(codeBytes), name: name}
		for j := uint32(0); j < polyCount; j++ {
			p, err := r.decodePolygon()
			if err != nil {
				return nil, err
			}
			c.polys = append(c.polys, p)
		}
		c.bbox = bboxOfPolys(c.polys)
		countries = append(countries, c)
	}
	return countries, nil
}

func (r *datasetReader) decodePolygon() (polygon, error) {
	ringCount, err := r.u32()
	if err != nil {
		return polygon{}, err
	}
	p := polygon{}
	for j := uint32(0); j < ringCount; j++ {
		hole, err := r.u8()
		if err != nil {
			return polygon{}, err
		}
		nPts, err := r.u32()
		if err != nil {
			return polygon{}, err
		}
		ring := ring{hole: hole != 0}
		for k := uint32(0); k < nPts; k++ {
			lat, err := r.i32()
			if err != nil {
				return polygon{}, err
			}
			lon, err := r.i32()
			if err != nil {
				return polygon{}, err
			}
			ring.pts = append(ring.pts, geoPoint{
				lat: float64(lat) / coordScale,
				lon: float64(lon) / coordScale,
			})
		}
		ring.bbox = bboxOfPoints(ring.pts)
		if !ring.hole {
			p.bbox = unionBBox(p.bbox, ring.bbox, j == 0)
		}
		p.rings = append(p.rings, ring)
	}
	return p, nil
}

func (r *datasetReader) decodeAdmin1() (map[string]string, error) {
	n, err := r.u32()
	if err != nil {
		return nil, err
	}
	m := make(map[string]string, n)
	for i := uint32(0); i < n; i++ {
		ccBytes, err := r.raw(2)
		if err != nil {
			return nil, err
		}
		code, err := r.string()
		if err != nil {
			return nil, err
		}
		name, err := r.string()
		if err != nil {
			return nil, err
		}
		m[string(ccBytes)+"."+code] = name
	}
	return m, nil
}

func (r *datasetReader) decodeLocalities() ([]locality, error) {
	n, err := r.u32()
	if err != nil {
		return nil, err
	}
	localities := make([]locality, 0, n)
	for i := uint32(0); i < n; i++ {
		id, err := r.u32()
		if err != nil {
			return nil, err
		}
		lat, err := r.i32()
		if err != nil {
			return nil, err
		}
		lon, err := r.i32()
		if err != nil {
			return nil, err
		}
		ccBytes, err := r.raw(2)
		if err != nil {
			return nil, err
		}
		admin1, err := r.string()
		if err != nil {
			return nil, err
		}
		name, err := r.string()
		if err != nil {
			return nil, err
		}
		localities = append(localities, locality{
			id:     int64(id),
			lat:    float64(lat) / coordScale,
			lon:    float64(lon) / coordScale,
			cc:     string(ccBytes),
			admin1: admin1,
			name:   name,
		})
	}
	return localities, nil
}

// ---------- resolution ----------

func (d *dataset) resolve(lat, lon float64) *Place {
	if lat < -90 || lat > 90 || lon < -180 || lon > 180 || math.IsNaN(lat) || math.IsNaN(lon) {
		return nil
	}

	cc, countryName := d.countryAt(lat, lon)

	if cc == "" {
		// coarse coastline fallback: the nearest locality's country, when
		// one is close enough that "in the water but plainly inside a
		// country" is the right reading
		if l := d.nearestLocality(lat, lon, "", 25); l != nil {
			cc = l.cc
		}
	}

	if cc == "" {
		// no country at all: a locality within 50 km is still worth naming
		l := d.nearestLocality(lat, lon, "", 50)
		if l == nil {
			return nil
		}
		return d.placeFor(l)
	}

	l := d.nearestLocality(lat, lon, cc, 50)
	if l == nil {
		return &Place{CountryCode: cc, Country: countryName}
	}
	return d.placeFor(l)
}

// placeFor builds the Place a locality resolves to, filling in the country
// and region names from the dataset's dictionaries.
func (d *dataset) placeFor(l *locality) *Place {
	p := &Place{
		CountryCode: l.cc,
		Admin1Code:  l.admin1,
		LocalityId:  l.id,
		Locality:    l.name,
	}
	p.Country = d.countryName(l.cc)
	if l.admin1 != "" {
		p.Admin1 = d.admin1Names[l.cc+"."+l.admin1]
	}
	return p
}

func (d *dataset) countryName(code string) string {
	for i := range d.countries {
		if d.countries[i].code == code {
			return d.countries[i].name
		}
	}
	return ""
}

// countryAt reports the ISO-3166 alpha-2 code of the country whose polygons
// contain the point, or "" when none does. Holes are honoured (a point in
// Lesotho is not in South Africa).
func (d *dataset) countryAt(lat, lon float64) (string, string) {
	for i := range d.countries {
		c := &d.countries[i]
		if !c.bbox.contains(lat, lon) {
			continue
		}
		if countryContains(c, lat, lon) {
			return c.code, c.name
		}
	}
	return "", ""
}

func countryContains(c *country, lat, lon float64) bool {
	for pi := range c.polys {
		if !c.polys[pi].bbox.contains(lat, lon) {
			continue
		}
		if polygonContains(&c.polys[pi], lat, lon) {
			return true
		}
	}
	return false
}

// polygonContains reports whether the point is inside the polygon: inside
// at least one outer ring and no hole ring. Ray casting with a bounding-box
// pre-check per ring.
func polygonContains(p *polygon, lat, lon float64) bool {
	inOuter := false
	for ri := range p.rings {
		r := &p.rings[ri]
		if r.hole {
			continue
		}
		if !r.bbox.contains(lat, lon) {
			continue
		}
		if rayCasts(r.pts, lat, lon) {
			inOuter = true
			break
		}
	}
	if !inOuter {
		return false
	}
	for ri := range p.rings {
		r := &p.rings[ri]
		if !r.hole {
			continue
		}
		if !r.bbox.contains(lat, lon) {
			continue
		}
		if rayCasts(r.pts, lat, lon) {
			return false
		}
	}
	return true
}

// rayCasts is the even-odd ray-casting test: cast a ray eastward from the
// point and count edge crossings.
func rayCasts(pts []geoPoint, lat, lon float64) bool {
	inside := false
	n := len(pts)
	for i, j := 0, n-1; i < n; j, i = i, i+1 {
		// edge from pts[i] to pts[j] (j trails i)
		li, lj := pts[i].lat, pts[j].lat
		oi, oj := pts[i].lon, pts[j].lon
		if (li > lat) != (lj > lat) {
			cross := oj + (lat-lj)/(li-lj)*(oi-oj)
			if lon < cross {
				inside = !inside
			}
		}
	}
	return inside
}

// nearestLocality finds the nearest locality to (lat, lon) among those in
// countryCode (all of them when countryCode is ""), within radiusKm. nil
// when none is close enough.
func (d *dataset) nearestLocality(lat, lon float64, countryCode string, radiusKm float64) *locality {
	if d.grid == nil {
		return nil
	}

	x0, y0 := cellOf(lat, lon)
	// how many cells the radius spans, per axis
	dLat := int(math.Ceil(radiusKm / kmPerDegree))
	cos := math.Cos(lat * math.Pi / 180)
	dLon := 1
	if cos > 1e-6 {
		dLon = int(math.Ceil(radiusKm / (kmPerDegree * cos)))
	}
	if dLon > 180 {
		dLon = 180
	}

	var best *locality
	bestDist := radiusKm

	for dy := -dLat; dy <= dLat; dy++ {
		y := y0 + int32(dy)
		if y < -90 || y > 89 {
			continue
		}
		row, ok := d.grid[y]
		if !ok {
			continue
		}
		for dx := -dLon; dx <= dLon; dx++ {
			x := x0 + int32(dx)
			// wrap longitude across the antimeridian
			for x < -180 {
				x += 360
			}
			for x > 180 {
				x -= 360
			}
			for _, idx := range row[x] {
				l := &d.localities[idx]
				if countryCode != "" && l.cc != countryCode {
					continue
				}
				dist := haversineKm(lat, lon, l.lat, l.lon)
				if dist < bestDist {
					bestDist = dist
					best = l
				}
			}
		}
	}
	return best
}

func haversineKm(lat1, lon1, lat2, lon2 float64) float64 {
	phi1 := lat1 * math.Pi / 180
	phi2 := lat2 * math.Pi / 180
	dPhi := (lat2 - lat1) * math.Pi / 180
	dLambda := (lon2 - lon1) * math.Pi / 180
	a := math.Sin(dPhi/2)*math.Sin(dPhi/2) +
		math.Cos(phi1)*math.Cos(phi2)*math.Sin(dLambda/2)*math.Sin(dLambda/2)
	c := 2 * math.Atan2(math.Sqrt(a), math.Sqrt(1-a))
	return earthRadiusKm * c
}

// ---------- small geometry helpers ----------

func bboxOfPoints(pts []geoPoint) bbox {
	b := bbox{
		minLat: math.MaxFloat64, maxLat: -math.MaxFloat64,
		minLon: math.MaxFloat64, maxLon: -math.MaxFloat64,
	}
	for _, p := range pts {
		if p.lat < b.minLat {
			b.minLat = p.lat
		}
		if p.lat > b.maxLat {
			b.maxLat = p.lat
		}
		if p.lon < b.minLon {
			b.minLon = p.lon
		}
		if p.lon > b.maxLon {
			b.maxLon = p.lon
		}
	}
	return b
}

func bboxOfPolys(polys []polygon) bbox {
	var b bbox
	first := true
	for i := range polys {
		if first {
			b = polys[i].bbox
			first = false
			continue
		}
		b = unionBBox(b, polys[i].bbox, false)
	}
	return b
}

func unionBBox(a, b bbox, first bool) bbox {
	if first {
		return b
	}
	if b.minLat < a.minLat {
		a.minLat = b.minLat
	}
	if b.maxLat > a.maxLat {
		a.maxLat = b.maxLat
	}
	if b.minLon < a.minLon {
		a.minLon = b.minLon
	}
	if b.maxLon > a.maxLon {
		a.maxLon = b.maxLon
	}
	return a
}
