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

// Package geo resolves a photo's GPS coordinates to a Place - city, region
// and country, in English - entirely offline, against a dataset generated
// from GeoNames (CC-BY 4.0) and Natural Earth (public domain) and embedded
// in the binary. See README.md for the dataset's provenance and how to
// regenerate it.
//
// The package is deliberately a pure, in-process library with no I/O of its
// own beyond the embedded file: the gallery service is its only consumer,
// and there is no network access, no external service and no API key - the
// whole point is that place resolution needs none of those (user story 13).
package geo

import "sync"

// Version is the version of the embedded dataset AND of the resolution
// logic. It is bumped whenever either changes; the gallery service stores
// it on every photo it resolves (GalleryPhoto.GeoVersion) and its metadata
// sweep re-resolves stored coordinates from photos whose stored version is
// lower. Bumping this constant alone is enough to schedule that pass - no
// other coordination exists or is needed.
const Version = 1

// Place is where a photo was taken, as specific as offline resolution
// against the embedded dataset allows: a country, an admin-1 region (the
// GeoNames form "CC.code", e.g. "DE.02") and a locality (city/town/village,
// identified by its GeoNames id). All names are English; any part may be
// empty - a photo in open ocean resolves to nothing at all, a photo on a
// mountain may resolve to a country only.
//
// The struct carries bson/json tags because the gallery service stores it
// as an embedded document on GalleryPhoto and ships it (flattened) through
// the delta feed; the package itself does no I/O.
type Place struct {
	CountryCode string `bson:"countryCode" json:"countryCode"`
	Country     string `bson:"country" json:"country"`

	Admin1Code string `bson:"admin1Code" json:"admin1Code"`
	Admin1     string `bson:"admin1" json:"admin1"`

	// LocalityId is the GeoNames id of the locality, stable across dataset
	// regenerations and usable as the app's filter key.
	LocalityId int64  `bson:"localityId" json:"localityId"`
	Locality   string `bson:"locality" json:"locality"`
}

// IsEmpty reports whether p resolves to nothing at all.
func (p *Place) IsEmpty() bool {
	return p == nil ||
		(p.CountryCode == "" && p.Country == "" &&
			p.Admin1Code == "" && p.Admin1 == "" &&
			p.LocalityId == 0 && p.Locality == "")
}

var (
	loadOnce sync.Once
	loadErr  error
	data     *dataset
)

// Resolve resolves (lat, lon) - WGS84 - to a Place, or nil when the point
// is far from any populated place and inside no country polygon (open
// ocean, the middle of a desert larger than the search radii).
//
// The rule, per the spec:
//
//  1. Country by point-in-polygon against Natural Earth admin-0 (1:50m).
//     If no polygon contains the point (the 1:50m coastline is coarse), the
//     nearest locality's country when that locality is within 25 km.
//  2. Locality: the nearest GeoNames populated place in that country within
//     50 km; otherwise none. The region comes from that locality's admin1.
//  3. With no country at all: the nearest place globally within 50 km.
//
// Resolution coordinates outside the valid WGS84 ranges return nil - the
// caller treats garbage as absent before ever calling this.
//
// The dataset is loaded once, lazily, and is safe for concurrent use.
func Resolve(lat, lon float64) *Place {
	d, err := load()
	if err != nil || d == nil {
		// a broken or empty dataset degrades to "no place", never to an
		// error: place resolution is best-effort enrichment of a photo,
		// and a photo without a place is a normal, storable state
		return nil
	}
	return d.resolve(lat, lon)
}

// LoadError reports the error (if any) hit while loading the embedded
// dataset, for tests and startup diagnostics. Resolve itself never fails -
// see its doc.
func LoadError() error {
	_, err := load()
	return err
}

func load() (*dataset, error) {
	loadOnce.Do(func() {
		d, err := decodeDataset(datasetBytes)
		if err != nil {
			loadErr = err
			return
		}
		d.buildIndex()
		data = d
	})
	return data, loadErr
}
