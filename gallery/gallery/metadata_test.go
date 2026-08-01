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

package gallery_test

import (
	"bytes"
	"testing"
	"time"

	"github.com/rwcarlsen/goexif/exif"
	"github.com/stretchr/testify/assert"
)

// This test exercises only the hand-built EXIF fixture helper against the
// real goexif decoder, independent of the gallery service - a cheap sanity
// check that the fixture bytes are well-formed before relying on them in
// the NATS-boundary integration tests.
func TestExifFixtureIsDecodable(t *testing.T) {
	data := buildJPEGWithExif(t, 8, 6, "2019:06:15 10:20:30", 6)

	x, err := exif.Decode(bytes.NewReader(data))
	if !assert.NoError(t, err) {
		return
	}

	dt, err := x.DateTime()
	assert.NoError(t, err)
	assert.Equal(t, time.Date(2019, 6, 15, 10, 20, 30, 0, dt.Location()), dt)

	tag, err := x.Get(exif.Orientation)
	assert.NoError(t, err)
	v, err := tag.Int(0)
	assert.NoError(t, err)
	assert.Equal(t, 6, v)
}

func TestExifFixtureWithoutTagsHasNeitherDateNorOrientation(t *testing.T) {
	data := buildJPEGWithExif(t, 8, 6, "", 0)

	x, err := exif.Decode(bytes.NewReader(data))
	if !assert.NoError(t, err) {
		return
	}

	_, err = x.DateTime()
	assert.Error(t, err)

	_, err = x.Get(exif.Orientation)
	assert.Error(t, err)
}

func TestPNGFixtureHasNoExif(t *testing.T) {
	data := buildPNG(t, 5, 5)
	_, err := exif.Decode(bytes.NewReader(data))
	assert.Error(t, err)
}
