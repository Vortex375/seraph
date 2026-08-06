// Copyright © 2026 Benjamin Schmitz

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

package e2e

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.mongodb.org/mongo-driver/bson"
	"umbasa.net/seraph/gallery/gallery"
)

// realPixelPhoto is a real, full-resolution JPEG taken on a Pixel 6
// (testdata/PXL_20240308_190141760.jpg) carrying a real EXIF APP1 segment with
// DateTimeOriginal = 2024:03:08 20:01:41. Unlike minJpeg (a JFIF-only stub with
// no EXIF), this fixture exercises the gallery's extractForEvent EXIF path
// against real-world camera output end to end through the actual backup route.
//
// Loaded lazily so the suite does not fail at init if the testdata file is
// absent (e.g. a shallow checkout); the test that needs it calls
// requireRealPixelPhoto and skips if the fixture is unavailable.
var realPixelPhoto []byte

func requireRealPixelPhoto(t *testing.T) []byte {
	t.Helper()
	if realPixelPhoto == nil {
		data, err := os.ReadFile("testdata/PXL_20240308_190141760.jpg")
		if err != nil {
			t.Skipf("testdata/PXL_20240308_190141760.jpg not available: %v", err)
		}
		realPixelPhoto = data
	}
	require.NotEmpty(t, realPixelPhoto, "real Pixel photo fixture must be non-empty")
	return realPixelPhoto
}

// realPhotoCaptureDate is the EXIF DateTimeOriginal embedded in
// testdata/PXL_20240308_190141760.jpg, parsed the same way the gallery service
// parses it (metadata.go exifCaptureDate: time.ParseInLocation with UTC), so
// the assertion compares apples to apples. CapturedAt is stored as Unix
// seconds.
var realPhotoCaptureDate = time.Date(2024, 3, 8, 20, 1, 41, 0, time.UTC)

// TestE2EGalleryPipelineExifThroughRealUpload proves the EXIF extraction the
// user's gallery ordering depends on actually runs when a photo arrives
// through the REAL backup route the phone uses - a WebDAV PUT through the
// api-gateway, the same path HeadlessWebDavBackend.upload takes - rather than
// only against a hand-published FileChangedEvent (which is what the existing
// gallery-only TestRealWorldPixelPhotoExtractionIsExtracted and
// TestPhotoWithExifCaptureDateIsIngested do).
//
// Concretely this is the one test that would have caught "the gallery shows
// everything sorted by upload time" against the real upload route: it PUTs a
// real Pixel 6 photo through the gateway, then asserts:
//
//  1. The gallery read model (galleryPhotos) has capturedAtSource == "exif"
//     and capturedAt == the photo's EXIF DateTimeOriginal, NOT the upload
//     time. metadataPending == false (live ingestion ran full extraction).
//  2. The gallery listing endpoint (GET /api/gallery/photos, what the app
//     renders) serves the photo with the same EXIF-derived capturedAt and
//     source - so the app would show it under the date it was TAKEN, not
//     under today.
//  3. The delta feed (GET /api/gallery/delta, what the phone polls to flip
//     origin device->both) serves the photo with the EXIF date and
//     metadataPending == false - so the phone's Verified gate closes against
//     the real capture date.
//
// A regression at any layer - file-provider not publishing a FileInfoEvent on
// stat, file-indexer consumer stalled, FileChangedEvent not published,
// gallery prefix-cache dropping the event, or extractForEvent failing to
// parse EXIF - surfaces here as a poll timeout or a wrong capturedAtSource,
// rather than only as "no date in the photo" in the app's UI.
func TestE2EGalleryPipelineExifThroughRealUpload(t *testing.T) {
	realData := requireRealPixelPhoto(t)

	relPath := galleryFolder + "/PXL_e2e_exif.jpg"

	// Reset the specific file + gallery state from any prior run, so the
	// test starts clean without tearing down the whole stack. The upsert is
	// idempotent on (providerId, path), so leftover state would mask a
	// regression by serving a stale row.
	cleanupGalleryPipelineState(t, relPath)
	mongoClient.Database(galleryDbName).Collection("gallerySourceFolders").
		DeleteOne(context.Background(), bson.M{"spaceProviderId": spaceProviderId, "path": galleryFolder})

	// 1. Add the Gallery Source Folder BEFORE uploading, so the prefix cache
	//    matches the FileChangedEvent the upload triggers. Backfill finds an
	//    empty file index and completes immediately; the photo reaches the
	//    read model via the LIVE event path - which is the path that performs
	//    full byte-level EXIF extraction (extractForEvent,
	//    metadataPending=false). This is the user's "upload into an
	//    already-configured folder" scenario.
	addGallerySourceFolder(t, galleryFolder)

	// 2. PUT the real Pixel photo through the WebDAV endpoint (the path the
	//    phone's HeadlessWebDavBackend.upload takes), then stat it through
	//    the file-provider client (the path the phone's disambiguation loop
	//    takes after every PUT) so the file-provider publishes the
	//    FileInfoEvent file-indexer ingests and turns into a FileChangedEvent.
	uploadAndStat(t, relPath, realData)

	// 3. The photo reaches the file-indexer's Mongo `files` collection.
	requireEventualFileIndexRow(t, relPath)

	// 4. The photo reaches the gallery read model with its Capture Date
	//    extracted from EXIF. This is the core assertion: extraction ran
	//    through the real backup route, not just against a hand-published
	//    event. capturedAtSource == "exif" is only written by rung one of
	//    the fallback chain (metadata.go exifCaptureDate -> ingest.go
	//    resolveCaptureDate), so it is the single field that distinguishes
	//    "extraction ran" from "extraction was skipped".
	photo := requireEventualGalleryPhoto(t, relPath)
	assert.Equal(t, providerId, photo["providerId"], "gallery providerId should be the physical file-provider id")
	assert.Equal(t, relPath, photo["path"], "gallery path should be the physical path")
	assert.False(t, photo["deleted"].(bool), "photo must not be marked deleted")
	assert.Equal(t, gallery.CaptureDateSourceExif, photo["capturedAtSource"],
		"a real Pixel photo uploaded through the backup route must have capturedAtSource=exif (extraction ran end to end)")
	assert.Equal(t, realPhotoCaptureDate.Unix(), photo["capturedAt"],
		"capturedAt must be the EXIF DateTimeOriginal (2024-03-08 20:01:41 UTC), not the upload time")
	pending, _ := photo["metadataPending"].(bool)
	assert.False(t, pending, "live-ingested photo must not be metadataPending")
	assert.NotZero(t, photo["width"], "EXIF/dimension extraction should populate width for a real photo")
	assert.NotZero(t, photo["height"], "EXIF/dimension extraction should populate height for a real photo")
	t.Logf("gallery photo: capturedAt=%v capturedAtSource=%v width=%v height=%v metadataPending=%v",
		photo["capturedAt"], photo["capturedAtSource"], photo["width"], photo["height"], photo["metadataPending"])

	// 5. The gallery listing endpoint (GET /api/gallery/photos, the one the
	//    app's grid renders from) serves the photo with the EXIF-derived
	//    Capture Date, so the app would show it under the date it was TAKEN.
	//    A gallery that only had upload time would show it under today.
	item := requireEventualGalleryListingContains(t, relPath)
	assert.Equal(t, spaceProviderId, item.ProviderId, "listing providerId should be the space providerId")
	assert.Equal(t, relPath, item.Path, "listing path should be the space path")
	assert.Equal(t, realPhotoCaptureDate.Unix(), item.CapturedAt,
		"listing capturedAt must be the EXIF date, not upload time")
	assert.Equal(t, gallery.CaptureDateSourceExif, item.CapturedAtSource,
		"listing capturedAtSource must be exif")

	// 6. The delta feed serves the photo with the EXIF-derived Capture Date
	//    and metadataPending == false, so a phone polling the feed flips its
	//    origin device->both (Verified) against the real capture date, and
	//    another device sees the photo with the correct date. This is the
	//    exact request the phone's GallerySyncService.sync() makes.
	deltaItem := requireEventualDeltaItem(t, relPath)
	assert.False(t, deltaItem.Tombstone, "delta item must not be a tombstone for a present photo")
	assert.Equal(t, realPhotoCaptureDate.Unix(), deltaItem.CapturedAt,
		"delta capturedAt must be the EXIF date, not upload time")
	assert.False(t, deltaItem.MetadataPending, "live-ingested photo must not be metadataPending in the delta feed")
	t.Logf("delta item: seq=%v capturedAt=%v metadataPending=%v",
		deltaItem.Seq, deltaItem.CapturedAt, deltaItem.MetadataPending)
}

// galleryListItem mirrors the GalleryListItem JSON the gateway returns from
// GET /api/gallery/photos, so the test can assert on the capture-date fields
// the app actually renders.
type galleryListItem struct {
	ProviderId       string `json:"providerId"`
	Path             string `json:"path"`
	CapturedAt       int64  `json:"capturedAt"`
	CapturedAtSource string `json:"capturedAtSource"`
	Size             int64  `json:"size"`
}

// requireEventualGalleryListingContains polls GET /api/gallery/photos (the
// endpoint the app's gallery grid renders from) until it returns relPath,
// returning the matching item. The gallery sorts by (capturedAt desc, _id
// asc) server-side (query.go listSort), so the returned order is the order the
// app displays. A timeout means the photo reached the read model but never
// became visible to the listing - a regression at the query/translate layer.
func requireEventualGalleryListingContains(t *testing.T, relPath string) galleryListItem {
	t.Helper()
	deadline := time.Now().Add(galleryPipelineTimeout)
	for time.Now().Before(deadline) {
		resp, err := http.Get(gatewayBase + "/api/gallery/photos?pageSize=100")
		require.NoError(t, err)
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("gallery listing: want 200, got %d (body=%s)", resp.StatusCode, body)
		}
		var page struct {
			Items     []galleryListItem `json:"items"`
			NextCursor string           `json:"nextCursor"`
			HasMore    bool             `json:"hasMore"`
		}
		require.NoError(t, json.Unmarshal(body, &page))

		for _, it := range page.Items {
			if it.Path == relPath {
				return it
			}
		}

		// Walk remaining pages of this poll before sleeping, so a large
		// gallery does not cause the test to miss an item on a later page.
		cursor := page.NextCursor
		for page.HasMore {
			resp, err := http.Get(fmt.Sprintf("%s/api/gallery/photos?pageSize=100&cursor=%s", gatewayBase, cursor))
			require.NoError(t, err)
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			require.NoError(t, json.Unmarshal(body, &page))
			for _, it := range page.Items {
				if it.Path == relPath {
					return it
				}
			}
			cursor = page.NextCursor
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Fatalf("gallery listing never served %s within %s", relPath, galleryPipelineTimeout)
	return galleryListItem{}
}
