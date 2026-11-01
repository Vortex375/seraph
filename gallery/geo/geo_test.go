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
	"sync"
	"testing"
)

// These tests run against the REAL embedded dataset (the committed
// data/geodata.bin.gz), not fixtures: the dataset is deterministic and
// committed, so "a city centre resolves to that city" is a stable,
// meaningful assertion, and it guards the whole generation pipeline -
// sources, generator, encoding - with one test run.

// known points and their expected resolution, per the spec's test list
func TestResolveKnownPoints(t *testing.T) {
	cases := []struct {
		name string
		lat  float64
		lon  float64
		// want* empty means "must be empty"
		wantCountryCode string
		wantCountry     string
		wantLocality    string
		wantAdmin1      string
		// the region code in GeoNames' "CC.code" form, when the place has a
		// region at all - the same form the spec keys the mirror's place
		// filter by
		wantAdmin1Code string
	}{
		{
			name:            "city centre: Lisbon",
			lat:             38.7223,
			lon:             -9.1393,
			wantCountryCode: "PT",
			wantCountry:     "Portugal",
			// the city itself, never a neighbourhood inside it (city
			// sections are excluded from the dataset)
			wantLocality: "Lisbon",
			// admin1CodesASCII's ASCII name for Lisbon district
			wantAdmin1:     "Lisbon",
			wantAdmin1Code: "PT.14",
		},
		{
			name:            "border town west of the Rhine: Strasbourg",
			lat:             48.5734,
			lon:             7.7521,
			wantCountryCode: "FR",
			wantCountry:     "France",
			wantLocality:    "Strasbourg",
		},
		{
			name:            "border town east of the Rhine: Kehl",
			lat:             48.5733,
			lon:             7.8139,
			wantCountryCode: "DE",
			wantCountry:     "Germany",
			wantLocality:    "Kehl",
		},
		{
			name:            "border town in the trilingual corner: Basel",
			lat:             47.5596,
			lon:             7.5886,
			wantCountryCode: "CH",
			wantCountry:     "Switzerland",
			wantLocality:    "Basel",
		},
		{
			name:            "coastal water just off a port - the 25 km nearest-locality fallback",
			lat:             38.68,
			lon:             -9.45, // Atlantic, off Cascais
			wantCountryCode: "PT",
			wantCountry:     "Portugal",
			// the fallback's nearest locality is the place shown
			wantLocality: "Cascais",
		},
		{
			name: "open ocean",
			lat:  30.0,
			lon:  -40.0,
		},
		{
			// interior Greenland: inside the country polygon, no locality
			// within 50 km - country only
			name:            "remote point, country only",
			lat:             71.0,
			lon:             -40.0,
			wantCountryCode: "GL",
			wantCountry:     "Greenland",
		},
		{
			name:            "antimeridian: eastern Fiji (Suva sits at 178.44 E)",
			lat:             -18.14,
			lon:             178.44,
			wantCountryCode: "FJ",
			wantCountry:     "Fiji",
			wantLocality:    "Suva",
		},
	}

	if err := LoadError(); err != nil {
		t.Fatalf("dataset failed to load: %v", err)
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p := Resolve(tc.lat, tc.lon)
			if tc.wantCountryCode == "" {
				if !p.IsEmpty() {
					t.Fatalf("expected no place, got %+v", p)
				}
				return
			}
			if p == nil {
				t.Fatalf("expected a place, got nil")
			}
			if p.CountryCode != tc.wantCountryCode {
				t.Errorf("country code: got %q, want %q (place: %+v)", p.CountryCode, tc.wantCountryCode, p)
			}
			if tc.wantCountry != "" && p.Country != tc.wantCountry {
				t.Errorf("country: got %q, want %q", p.Country, tc.wantCountry)
			}
			if tc.wantLocality != "" && p.Locality != tc.wantLocality {
				t.Errorf("locality: got %q, want %q", p.Locality, tc.wantLocality)
			}
			if tc.wantAdmin1 != "" && p.Admin1 != tc.wantAdmin1 {
				t.Errorf("admin1: got %q, want %q", p.Admin1, tc.wantAdmin1)
			}
			if tc.wantAdmin1Code != "" && p.Admin1Code != tc.wantAdmin1Code {
				t.Errorf("admin1 code: got %q, want the CC.code form %q", p.Admin1Code, tc.wantAdmin1Code)
			}
			if tc.wantLocality == "" && p.Locality != "" {
				t.Errorf("expected no locality, got %q", p.Locality)
			}
		})
	}
}

// Names must be English where GeoNames has an English preferred name.
func TestResolveEnglishNames(t *testing.T) {
	p := Resolve(48.1374, 11.5755) // Munich city centre
	if p == nil {
		t.Fatal("no place for Munich")
	}
	if p.Locality != "Munich" {
		t.Errorf("locality: got %q, want the English name %q (GeoNames' local name would be \"München\")", p.Locality, "Munich")
	}
	if p.Country != "Germany" {
		t.Errorf("country: got %q, want Germany", p.Country)
	}
}

func TestResolveInvalidCoordinates(t *testing.T) {
	if p := Resolve(95, 0); !p.IsEmpty() {
		t.Errorf("lat 95: expected empty, got %+v", p)
	}
	if p := Resolve(0, 200); !p.IsEmpty() {
		t.Errorf("lon 200: expected empty, got %+v", p)
	}
	if p := Resolve(2000, 0); !p.IsEmpty() {
		t.Errorf("huge lat: expected empty, got %+v", p)
	}
}

func TestResolveConcurrencySafe(t *testing.T) {
	// exercise loading and resolving concurrently: the dataset is built
	// once under a sync.Once and is read-only afterwards
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 200; j++ {
				_ = Resolve(38.7223, -9.1393)
				_ = Resolve(30, -40)
			}
		}()
	}
	wg.Wait()
}

func BenchmarkResolve(b *testing.B) {
	for i := 0; i < b.N; i++ {
		Resolve(38.7223, -9.1393)
	}
}
