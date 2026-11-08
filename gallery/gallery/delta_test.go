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

package gallery

import (
	"encoding/json"
	"math"
	"testing"
)

func TestDeltaItemDropsNonFiniteCoordinates(t *testing.T) {
	nan, inf := math.NaN(), math.Inf(1)
	folders := []resolvedFolder{{providerId: "p", path: "/", spaceProviderId: "s", spacePath: "/"}}
	row := deltaRow{seq: 1, photo: GalleryPhoto{ProviderId: "p", Path: "/a.jpg", Seq: 1, Lat: &nan, Lon: &inf}}

	item, emit := deltaItemFor(row, folders)
	if !emit {
		t.Fatal("expected the photo to be emitted")
	}
	if item.Lat != nil || item.Lon != nil {
		t.Fatalf("non-finite coordinates must be dropped, got %v, %v", *item.Lat, *item.Lon)
	}
	if _, err := json.Marshal(GalleryDeltaResponse{Items: []GalleryDeltaItem{item}}); err != nil {
		t.Fatalf("delta response must stay encodable: %v", err)
	}
}
