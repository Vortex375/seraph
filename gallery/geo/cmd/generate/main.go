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

// generate builds the embedded geo dataset from downloaded GeoNames and
// Natural Earth sources. It is run MANUALLY via `make` in gallery/geo -
// never at build or run time - so builds stay reproducible and offline.
// See ../README.md for the sources and their licences.
//
// Input files (see ../Makefile):
//
//   - cities500.txt            GeoNames cities500 (population >= 500)
//   - admin1CodesASCII.txt     GeoNames admin-1 codes ("CC.code" -> name)
//   - countryInfo.txt          GeoNames country info (ISO code -> name)
//   - geonames-en.tsv          English preferred names, pre-filtered out of
//     GeoNames alternateNamesV2 by the Makefile
//     (geonameid \t name)
//   - ne_50m_admin_0_countries.geojson
//     Natural Earth admin-0 countries, 1:50m
//
// Output: one gzipped binary file (see ../dataset.go's decodeDataset for
// the layout), written to the path given with -out, which the geo package
// embeds with go:embed. The file is committed; regeneration is manual.
package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const coordScale = 100000
const formatVersion = 1

func main() {
	cities := flag.String("cities", "downloads/cities500.txt", "GeoNames cities file")
	admin1 := flag.String("admin1", "downloads/admin1CodesASCII.txt", "GeoNames admin1 codes")
	countries := flag.String("countries", "downloads/countryInfo.txt", "GeoNames countryInfo")
	english := flag.String("english", "downloads/geonames-en.tsv", "English preferred names (geonameid\\tname)")
	neGeo := flag.String("natural-earth", "downloads/ne_50m_admin_0_countries.geojson", "Natural Earth admin-0 GeoJSON")
	out := flag.String("out", "data/geodata.bin.gz", "output file (committed, embedded)")
	flag.Parse()

	if err := run(*cities, *admin1, *countries, *english, *neGeo, *out); err != nil {
		log.Fatal(err)
	}
}

func run(citiesPath, admin1Path, countriesPath, englishPath, nePath, outPath string) error {
	countryNames, err := readCountries(countriesPath)
	if err != nil {
		return err
	}

	admin1Names, err := readAdmin1(admin1Path)
	if err != nil {
		return err
	}

	englishNames, err := readEnglish(englishPath)
	if err != nil {
		return err
	}

	localities, err := readCities(citiesPath, englishNames)
	if err != nil {
		return err
	}

	// countries with polygons, keyed by ISO alpha-2
	polyByCode, err := readNaturalEarth(nePath)
	if err != nil {
		return err
	}

	// Emit in a stable order (by code) so regeneration is reproducible:
	// same inputs, byte-identical output.
	codes := make([]string, 0, len(countryNames))
	for code := range countryNames {
		codes = append(codes, code)
	}
	sort.Strings(codes)

	var buf bytes.Buffer
	w := &writer{buf: &buf}
	w.raw([]byte("SGEO"))
	w.u8(formatVersion)

	w.u32(uint32(len(codes)))
	for _, code := range codes {
		polys := polyByCode[code]
		w.raw([]byte(code))
		w.str(countryNames[code])
		w.u32(uint32(len(polys)))
		for _, p := range polys {
			w.u32(uint32(len(p)))
			for _, ring := range p {
				if ring.hole {
					w.u8(1)
				} else {
					w.u8(0)
				}
				w.u32(uint32(len(ring.pts)))
				for _, pt := range ring.pts {
					w.i32(int32(pt[0] * coordScale)) // lat
					w.i32(int32(pt[1] * coordScale)) // lon
				}
			}
		}
	}

	admin1Codes := make([]string, 0, len(admin1Names))
	for code := range admin1Names {
		admin1Codes = append(admin1Codes, code)
	}
	sort.Strings(admin1Codes)

	w.u32(uint32(len(admin1Codes)))
	for _, code := range admin1Codes {
		dot := strings.Index(code, ".")
		if dot < 0 {
			continue
		}
		w.raw([]byte(code[:dot]))
		w.str(code[dot+1:])
		w.str(admin1Names[code])
	}

	w.u32(uint32(len(localities)))
	for i := range localities {
		l := &localities[i]
		w.u32(l.id)
		w.i32(int32(l.lat * coordScale))
		w.i32(int32(l.lon * coordScale))
		w.raw([]byte(l.cc))
		w.str(l.admin1)
		w.str(l.name)
	}

	if err := w.err; err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
		return err
	}
	f, err := os.Create(outPath)
	if err != nil {
		return err
	}
	defer f.Close()
	gz := gzip.NewWriter(f)
	if _, err := gz.Write(buf.Bytes()); err != nil {
		return err
	}
	if err := gz.Close(); err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}

	fmt.Printf("geo dataset: %d countries, %d admin1, %d localities; raw %d bytes, gzipped %d bytes\n",
		len(codes), len(admin1Names), len(localities), buf.Len(), fileSize(outPath))
	return nil
}

func fileSize(path string) int {
	st, err := os.Stat(path)
	if err != nil {
		return -1
	}
	return int(st.Size())
}

// ---------- input readers ----------

func readCountries(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	names := map[string]string{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "#") || line == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) < 5 {
			continue
		}
		code := fields[0]
		if len(code) != 2 {
			continue
		}
		names[code] = fields[4]
	}
	return names, sc.Err()
}

func readAdmin1(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	names := map[string]string{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<20)
	for sc.Scan() {
		fields := strings.Split(sc.Text(), "\t")
		if len(fields) < 3 {
			continue
		}
		// "CC.code\tname\tascii name\tgeonameid"
		names[fields[0]] = fields[1]
	}
	return names, sc.Err()
}

func readEnglish(path string) (map[uint32]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	names := map[uint32]string{}
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<20)
	for sc.Scan() {
		fields := strings.Split(sc.Text(), "\t")
		if len(fields) < 2 {
			continue
		}
		id, err := strconv.ParseUint(fields[0], 10, 64)
		if err != nil {
			continue
		}
		names[uint32(id)] = fields[1]
	}
	return names, sc.Err()
}

type city struct {
	id     uint32
	lat    float64
	lon    float64
	cc     string
	admin1 string
	name   string
}

func readCities(path string, english map[uint32]string) ([]city, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var cities []city
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<20)
	for sc.Scan() {
		fields := strings.Split(sc.Text(), "\t")
		if len(fields) < 11 {
			continue
		}
		id, err := strconv.ParseUint(fields[0], 10, 64)
		if err != nil {
			continue
		}
		lat, err := strconv.ParseFloat(fields[4], 64)
		if err != nil {
			continue
		}
		lon, err := strconv.ParseFloat(fields[5], 64)
		if err != nil {
			continue
		}
		// PPLX is a SECTION of a populated place (a neighbourhood). A city
		// centre must resolve to the city - user story 9 wants "Lisbon,
		// Lisbon, Portugal", not the Lisbon neighbourhood that happens to
		// sit a hundred metres nearer to the shutter - so sections are
		// excluded from the dataset entirely. All other P* codes are real
		// populated places (PPL, PPLC capital, PPLA seat, PPLL locality,
		// historical/abandoned ones included - a photo can be taken at
		// those too).
		if fields[7] == "PPLX" {
			continue
		}
		name := fields[1]
		if en, ok := english[uint32(id)]; ok && en != "" {
			name = en
		}
		cities = append(cities, city{
			id:     uint32(id),
			lat:    lat,
			lon:    lon,
			cc:     fields[8],
			admin1: fields[10],
			name:   name,
		})
	}
	return cities, sc.Err()
}

// geoRing is one polygon ring after GeoJSON parsing, as (lat, lon) pairs.
type geoRing struct {
	hole bool
	pts  [][2]float64
}

// readNaturalEarth parses Natural Earth's admin-0 GeoJSON into polygons
// keyed by ISO alpha-2 country code. Holes are honoured per GeoJSON's
// structural convention (first ring exterior, further rings holes) - see
// ringsFromPolygon.
func readNaturalEarth(path string) (map[string][][]geoRing, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var fc struct {
		Features []struct {
			Geometry struct {
				Type        string          `json:"type"`
				Coordinates json.RawMessage `json:"coordinates"`
			} `json:"geometry"`
			Properties map[string]any `json:"properties"`
		} `json:"features"`
	}
	if err := json.Unmarshal(data, &fc); err != nil {
		return nil, fmt.Errorf("parsing %s: %w", path, err)
	}

	result := map[string][][]geoRing{}
	for _, feat := range fc.Features {
		code := polygonCountryCode(feat.Properties)
		if code == "" {
			continue
		}
		rings, err := ringsFromGeometry(feat.Geometry.Type, feat.Geometry.Coordinates)
		if err != nil {
			return nil, err
		}
		if len(rings) > 0 {
			result[code] = append(result[code], rings)
		}
	}
	return result, nil
}

func polygonCountryCode(props map[string]any) string {
	// ISO_A2 is "-99" for a few countries whose two-letter code NE models
	// awkwardly (France, Norway); ISO_A2_EH is the "even holding" variant
	// that always carries the real code, so prefer it.
	for _, key := range []string{"ISO_A2_EH", "ISO_A2"} {
		if v, ok := props[key]; ok {
			if s, ok := v.(string); ok && len(s) == 2 && s != "-9" {
				return s
			}
		}
	}
	return ""
}

func ringsFromGeometry(typ string, raw json.RawMessage) ([]geoRing, error) {
	switch typ {
	case "Polygon":
		return ringsFromPolygon(raw)
	case "MultiPolygon":
		var polys []json.RawMessage
		if err := json.Unmarshal(raw, &polys); err != nil {
			return nil, err
		}
		var rings []geoRing
		for _, p := range polys {
			rs, err := ringsFromPolygon(p)
			if err != nil {
				return nil, err
			}
			rings = append(rings, rs...)
		}
		return rings, nil
	default:
		return nil, nil
	}
}

// ringsFromPolygon parses one GeoJSON polygon: coordinates is an array of
// rings, each an array of [lon, lat] pairs, first ring the exterior.
func ringsFromPolygon(raw json.RawMessage) ([]geoRing, error) {
	var coordRings [][][2]float64
	if err := json.Unmarshal(raw, &coordRings); err != nil {
		return nil, err
	}
	rings := make([]geoRing, 0, len(coordRings))
	for i, cr := range coordRings {
		if len(cr) < 4 {
			continue
		}
		pts := make([][2]float64, 0, len(cr)-1)
		for _, c := range cr[:len(cr)-1] { // drop the repeated closing point
			pts = append(pts, [2]float64{c[1], c[0]}) // lat, lon
		}
		// GeoJSON's structural convention (2008 spec and RFC 7946 alike):
		// the FIRST ring is the exterior, any further rings are holes -
		// regardless of winding, which Natural Earth's data does not
		// uniformly follow.
		rings = append(rings, geoRing{hole: i > 0, pts: pts})
	}
	return rings, nil
}

// ---------- binary writer ----------

type writer struct {
	buf *bytes.Buffer
	err error
}

func (w *writer) raw(b []byte) {
	if w.err != nil {
		return
	}
	w.buf.Write(b[:])
}

func (w *writer) u8(v uint8) {
	if w.err != nil {
		return
	}
	w.buf.WriteByte(v)
}

func (w *writer) u32(v uint32) {
	if w.err != nil {
		return
	}
	var b [4]byte
	binary.LittleEndian.PutUint32(b[:], v)
	w.buf.Write(b[:])
}

func (w *writer) i32(v int32) {
	if w.err != nil {
		return
	}
	var b [4]byte
	binary.LittleEndian.PutUint32(b[:], uint32(v))
	w.buf.Write(b[:])
}

func (w *writer) str(s string) {
	if w.err != nil {
		return
	}
	if len(s) > math.MaxUint16 {
		w.err = fmt.Errorf("string too long: %q", s)
		return
	}
	var b [2]byte
	binary.LittleEndian.PutUint16(b[:], uint16(len(s)))
	w.buf.Write(b[:])
	w.buf.WriteString(s)
}
