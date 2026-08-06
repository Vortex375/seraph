// Copyright © 2024 Benjamin Schmitz

// This file is part of Seraph <https://github.com/Vortex375/seraph>.

// Seraph is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License
// as published by the Free Software Foundation,
// either version 3 of the License, or (at your option) any later version.

// Seraph is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.

// You should have received a copy of the GNU Affero General Public License
// along with Seraph.  If not, see <http://www.gnu.org/licenses/>.

package gallery_test

import (
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/gallery/gallery"
)

// TestRealWorldPixelPhotoExtractionIsExtracted proves the full extraction
// pipeline against a real, full-resolution photo taken on a Pixel 6
// (testdata/PXL_20240308_190141760.jpg) rather than a hand-built EXIF fixture:
// the file travels through the real File Provider over NATS, gets decoded by
// goexif, and its DateTimeOriginal lands in the read model as the Capture
// Date with source "exif". This is the end-to-end evidence that metadata
// extraction works against real-world JPEG/EXIF today, independent of the
// hand-built fixture path the other tests rely on.
func TestRealWorldPixelPhotoExtractionIsExtracted(t *testing.T) {
	data, err := os.ReadFile("testdata/PXL_20240308_190141760.jpg")
	require.NoError(t, err, "testdata/PXL_20240308_190141760.jpg must exist (see testdata/README)")
	require.NotEmpty(t, data)

	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	dir := startFileProvider(t, "physical-photos")

	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})

	physicalPath := "/mounted/photos/holidays/PXL_20240308_190141760.jpg"
	writeFixture(t, dir, physicalPath, data)

	// ModTime deliberately differs from the EXIF date so the test fails if
	// the fallback chain picks the wrong rung: the file's mtime is "now"
	// (upload time), while the real capture date is 2024-03-08 from EXIF.
	modTime := time.Now().Unix()
	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventCreated, int64(len(data)), modTime, "image/jpeg")

	photo := waitForPhoto(t, db, "physical-photos", physicalPath)

	// The Capture Date must come from EXIF, not from ModTime.
	assert.Equal(t, gallery.CaptureDateSourceExif, photo.CapturedAtSource,
		"a real Pixel photo with DateTimeOriginal must sort by its EXIF date, not by upload time")
	// Pixel 6 DateTimeOriginal: 2024:03:08 20:01:41 (UTC parse, see exifCaptureDate).
	want := time.Date(2024, 3, 8, 20, 1, 41, 0, time.UTC).Unix()
	assert.Equal(t, want, photo.CapturedAt,
		"capturedAt must be the EXIF DateTimeOriginal, not the event ModTime (%d)", modTime)
	// Real dimensions from a full-resolution Pixel 6 shot.
	assert.NotZero(t, photo.Width)
	assert.NotZero(t, photo.Height)
	assert.Equal(t, "", photo.Unsupported)
	assert.False(t, photo.MetadataPending)
	assert.False(t, photo.Deleted)
}
