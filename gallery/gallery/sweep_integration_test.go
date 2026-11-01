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
	"umbasa.net/seraph/gallery/gallery/gallerytest"

	"context"
	"math"
	"strconv"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/gallery/gallery"
	"umbasa.net/seraph/gallery/geo"
)

// The metadata sweep runs at provider boot, so these tests seed the read
// model (and the File Provider's files) BEFORE the provider starts - unlike
// the live-ingestion tests, which drive everything through events after
// Start. startSweepProvider wires exactly that sequence.
func startSweepProvider(t *testing.T, seed func(dir string, nc *nats.Conn, db *mongo.Database)) (*nats.Conn, *mongo.Database) {
	t.Helper()

	provider, nc, db := getGalleryProvider(t)
	dir := startFileProvider(t, "physical-photos")
	subscribeSpaceResolve(t, nc, map[string][]string{"pino": {"photos"}})
	if seed != nil {
		seed(dir, nc, db)
	}
	if err := provider.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		provider.Stop()
		nc.Close()
	})

	return nc, db
}

// insertStalePhoto inserts a galleryPhotos document the way backfill left
// it before the metadata sweep existed: no metadataVersion field at all
// (pre-feature documents have none), Capture Date from the modTime rung,
// MetadataPending still set.
func insertStalePhoto(t *testing.T, db *mongo.Database, providerId, filePath string, extra bson.M) primitive.ObjectID {
	t.Helper()

	doc := bson.M{
		"providerId":       providerId,
		"path":             filePath,
		"capturedAt":       int64(1600000000),
		"capturedAtSource": gallery.CaptureDateSourceModTime,
		"width":            0,
		"height":           0,
		"orientation":      0,
		"size":             int64(1),
		"mime":             "image/jpeg",
		"unsupported":      "",
		"metadataPending":  true,
		"seq":              int64(0),
	}
	for k, v := range extra {
		doc[k] = v
	}
	res, err := db.Collection("galleryPhotos").InsertOne(context.Background(), doc)
	require.NoError(t, err)
	return res.InsertedID.(primitive.ObjectID)
}

// waitForPhotoState polls until findPhoto returns a photo satisfying cond,
// or fails after the deadline.
func waitForPhotoState(t *testing.T, db *mongo.Database, providerId, filePath string, cond func(*gallery.GalleryPhoto) bool, desc string) *gallery.GalleryPhoto {
	t.Helper()

	deadline := time.Now().Add(15 * time.Second)
	var last *gallery.GalleryPhoto
	for time.Now().Before(deadline) {
		last = findPhoto(t, db, providerId, filePath)
		if last != nil && cond(last) {
			return last
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("photo %s/%s never reached the expected state (%s); last: %+v", providerId, filePath, desc, last)
	return nil
}

// exifLisbonJPEG builds a fixture with the full capture-time chain: a
// zoneless wall clock, an OffsetTimeOriginal and GPS coordinates that
// resolve to Lisbon in the embedded geo dataset.
func exifLisbonJPEG(t *testing.T) []byte {
	t.Helper()
	return gallerytest.BuildJPEGWithExifSpec(t, 12, 8, gallerytest.ExifFixtureSpec{
		DateTimeOriginal:   "2021:07:05 14:30:00",
		OffsetTimeOriginal: "+02:00",
		GPS:                true,
		Lat:                38.7223,
		Lon:                -9.1393,
		LatRef:             "N",
		LonRef:             "W",
	})
}

// TestMetadataSweepReextractsStalePhotos covers ticket 03's core: a photo
// backfilled before the capture-time feature (no metadataVersion, Capture
// Date from the file's modification time, MetadataPending set) is
// re-extracted at boot through the File Provider, gains the true instant +
// offset + GPS coordinates + resolved Place, and has MetadataPending
// cleared - exactly as a live event would have healed it.
func TestMetadataSweepReextractsStalePhotos(t *testing.T) {
	requireIntegration(t)

	_, db := startSweepProvider(t, func(dir string, nc *nats.Conn, db *mongo.Database) {
		writeFixture(t, dir, "/holidays/with-everything.jpg", exifLisbonJPEG(t))
		// A PNG: valid, decodable, but carrying no EXIF at all - the
		// sweep must still process it (modTime rung, no offset, no place).
		writeFixture(t, dir, "/holidays/no-exif.png", gallerytest.BuildPNG(t, 7, 5))
		insertStalePhoto(t, db, "physical-photos", "/holidays/with-everything.jpg", nil)
		insertStalePhoto(t, db, "physical-photos", "/holidays/no-exif.png", bson.M{"mime": "image/png"})
	})

	// The EXIF photo: swept to the current version with the full
	// capture-time + Place result.
	photo := waitForPhotoState(t, db, "physical-photos", "/holidays/with-everything.jpg",
		func(p *gallery.GalleryPhoto) bool { return p.MetadataVersion == 2 },
		"re-extracted to metadataVersion 2")

	wall := time.Date(2021, 7, 5, 14, 30, 0, 0, time.UTC)
	expectedInstant := wall.Add(-2 * time.Hour).Unix()
	assert.Equal(t, expectedInstant, photo.CapturedAt,
		"the true instant is the EXIF wall clock minus the offset")
	require.NotNil(t, photo.CapturedAtOffset)
	assert.Equal(t, 7200, *photo.CapturedAtOffset)
	assert.Equal(t, gallery.CaptureDateSourceExif, photo.CapturedAtSource)
	assert.False(t, photo.MetadataPending, "the sweep must clear MetadataPending, not just live events")
	require.NotNil(t, photo.Lat)
	assert.InDelta(t, 38.7223, *photo.Lat, 1e-3)
	require.NotNil(t, photo.Lon)
	assert.InDelta(t, -9.1393, *photo.Lon, 1e-3)
	require.NotNil(t, photo.Place)
	assert.Equal(t, "PT", photo.Place.CountryCode)
	assert.Equal(t, "Lisbon", photo.Place.Locality)
	assert.Equal(t, geo.Version, photo.GeoVersion)
	assert.Greater(t, photo.Seq, int64(0), "a feed-visible change must bump Seq")

	// The EXIF-less photo: swept to the current version, but with no
	// offset and no Place - and no feed-visible change beyond clearing
	// MetadataPending (which is itself a bump).
	png := waitForPhotoState(t, db, "physical-photos", "/holidays/no-exif.png",
		func(p *gallery.GalleryPhoto) bool { return p.MetadataVersion == 2 },
		"re-extracted to metadataVersion 2")
	assert.Nil(t, png.CapturedAtOffset)
	assert.Nil(t, png.Place)
	assert.Equal(t, 0, png.GeoVersion, "no coordinates to resolve - a later dataset bump must not pick this photo up")
	assert.False(t, png.MetadataPending)
}

// TestMetadataSweepSkipsUnreadableFilesWithoutStalling covers ticket 03's
// "a photo whose file cannot be opened is skipped, keeps its version, and
// later photos are still processed" - and, with a full page (50) of
// unreadable files ahead of the readable one, the paging property that
// makes it true: the sweep advances its cursor past photos it could not
// process instead of re-fetching the same failing page forever.
func TestMetadataSweepSkipsUnreadableFilesWithoutStalling(t *testing.T) {
	requireIntegration(t)

	const unreadableCount = 55 // more than one sweep page of failures
	_, db := startSweepProvider(t, func(dir string, nc *nats.Conn, db *mongo.Database) {
		// The stale documents are seeded oldest-first: a full page (and
		// more) of files that do not exist, then ONE readable photo after
		// them. A re-query-the-same-filter sweep would retry the same
		// failing page forever and never reach it.
		for i := 0; i < unreadableCount; i++ {
			insertStalePhoto(t, db, "physical-photos",
				"/holidays/missing-"+strconv.Itoa(i)+".jpg", nil)
		}
		writeFixture(t, dir, "/holidays/readable.jpg", exifLisbonJPEG(t))
		insertStalePhoto(t, db, "physical-photos", "/holidays/readable.jpg", nil)
	})

	readable := waitForPhotoState(t, db, "physical-photos", "/holidays/readable.jpg",
		func(p *gallery.GalleryPhoto) bool { return p.MetadataVersion == 2 },
		"the readable photo behind a full page of unreadable ones still got swept")
	assert.Equal(t, 7200, *readable.CapturedAtOffset)

	// The unreadable ones keep their old version - retried on the next
	// boot, not silently promoted.
	missing := findPhoto(t, db, "physical-photos", "/holidays/missing-0.jpg")
	require.NotNil(t, missing)
	assert.Equal(t, 0, missing.MetadataVersion,
		"a photo whose file cannot be opened keeps its version")
}

// TestMetadataSweepConvergesWithLiveEvent covers the race rule: a live
// event and the boot sweep both targeting the same stale photo end in
// exactly one document at the current version carrying the LIVE event's
// extraction - the sweep's guarded write (still-stale AND not-deleted)
// can never overwrite a live event's fresher data.
func TestMetadataSweepConvergesWithLiveEvent(t *testing.T) {
	requireIntegration(t)

	nc, db := startSweepProvider(t, func(dir string, nc *nats.Conn, db *mongo.Database) {
		writeFixture(t, dir, "/holidays/raced.jpg", exifLisbonJPEG(t))
		insertStalePhoto(t, db, "physical-photos", "/holidays/raced.jpg", nil)
	})

	// A live event for the same path, published right after boot - while
	// the sweep is (or was just) working on the same document.
	publishFileChanged(t, nc, "physical-photos", "/holidays/raced.jpg",
		events.FileChangedEventCreated, int64(len(exifLisbonJPEG(t))), time.Now().Unix(), "image/jpeg")

	photo := waitForPhotoState(t, db, "physical-photos", "/holidays/raced.jpg",
		func(p *gallery.GalleryPhoto) bool { return p.MetadataVersion == 2 },
		"converged to the current version")

	// Whatever order the two writers committed in, the end state is the
	// live event's extraction - and there is exactly one document.
	assert.Equal(t, 7200, *photo.CapturedAtOffset)
	assert.False(t, photo.MetadataPending)
	count, err := db.Collection("galleryPhotos").CountDocuments(context.Background(),
		bson.M{"providerId": "physical-photos", "path": "/holidays/raced.jpg"})
	require.NoError(t, err)
	assert.Equal(t, int64(1), count, "the race must produce one document, not two")
}

// TestMetadataSweepDoesNotTouchTombstones covers: deleted photos are not
// swept - their stale bookkeeping is never resurrected.
func TestMetadataSweepDoesNotTouchTombstones(t *testing.T) {
	requireIntegration(t)

	_, db := startSweepProvider(t, func(dir string, nc *nats.Conn, db *mongo.Database) {
		insertStalePhoto(t, db, "physical-photos", "/holidays/deleted.jpg",
			bson.M{"deleted": true})
	})

	// Give the sweep time to run to completion (it processes everything
	// else first), then assert the tombstone is exactly as it was.
	time.Sleep(2 * time.Second)
	photo := findPhoto(t, db, "physical-photos", "/holidays/deleted.jpg")
	require.NotNil(t, photo)
	assert.Equal(t, 0, photo.MetadataVersion,
		"a deleted photo must not be re-extracted by the sweep")
	assert.True(t, photo.MetadataPending)
}

// TestGeoResolvePassReResolvesStoredCoordinates covers ticket 04's sweep
// half: photos already at the current metadata version but with
// coordinates and no Place (or an outdated dataset version) get their
// Place resolved from the STORED coordinates - no File Provider read - and
// Seq is bumped only when the resolved Place actually changed.
func TestGeoResolvePassReResolvesStoredCoordinates(t *testing.T) {
	requireIntegration(t)

	lisbonPlace := &geo.Place{
		CountryCode: "PT",
		Country:     "Portugal",
		Admin1Code:  "PT.14",
		Admin1:      "Lisbon",
		LocalityId:  2267057,
		Locality:    "Lisbon",
	}

	_, db := startSweepProvider(t, func(dir string, nc *nats.Conn, db *mongo.Database) {
		// A: coordinates, no place yet - the geo pass's main case.
		insertStalePhoto(t, db, "physical-photos", "/holidays/a.jpg", bson.M{
			"capturedAtSource": gallery.CaptureDateSourceExif,
			"metadataVersion":  2,
			"geoVersion":       0,
			"lat":              38.7223,
			"lon":              -9.1393,
			"seq":              int64(100),
		})
		// B: coordinates that resolve to nothing (open ocean) - still
		// marked as resolved against this dataset version, Seq untouched.
		insertStalePhoto(t, db, "physical-photos", "/holidays/b.jpg", bson.M{
			"capturedAtSource": gallery.CaptureDateSourceExif,
			"metadataVersion":  2,
			"geoVersion":       0,
			"lat":              47.0,
			"lon":              -30.0,
			"seq":              int64(100),
		})
		// C: already resolved at the current dataset version - untouched.
		insertStalePhoto(t, db, "physical-photos", "/holidays/c.jpg", bson.M{
			"capturedAtSource": gallery.CaptureDateSourceExif,
			"metadataVersion":  2,
			"geoVersion":       geo.Version,
			"lat":              38.7223,
			"lon":              -9.1393,
			"place":            lisbonPlace,
			"seq":              int64(100),
		})
		// D: an outdated dataset version, but the re-resolve yields the
		// SAME place - the version advances, Seq does not (nothing the
		// feed carries changed).
		insertStalePhoto(t, db, "physical-photos", "/holidays/d.jpg", bson.M{
			"capturedAtSource": gallery.CaptureDateSourceExif,
			"metadataVersion":  2,
			"geoVersion":       0,
			"lat":              38.7223,
			"lon":              -9.1393,
			"place":            lisbonPlace,
			"seq":              int64(100),
		})
	})

	// A: the Place appears, and the Seq bump carries it to the mirrors.
	a := waitForPhotoState(t, db, "physical-photos", "/holidays/a.jpg",
		func(p *gallery.GalleryPhoto) bool {
			return p.Place != nil && p.Place.CountryCode == "PT"
		}, "place resolved from stored coordinates")
	assert.Equal(t, geo.Version, a.GeoVersion)
	assert.Greater(t, a.Seq, int64(100), "a newly-resolved Place is feed-visible: Seq must bump")

	// B: resolved-to-nothing is still resolved - marked at the current
	// dataset version, place absent, Seq untouched.
	b := waitForPhotoState(t, db, "physical-photos", "/holidays/b.jpg",
		func(p *gallery.GalleryPhoto) bool { return p.GeoVersion == geo.Version },
		"marked resolved against the current dataset")
	assert.Nil(t, b.Place)
	assert.Equal(t, int64(100), b.Seq)

	// C: untouched - no re-resolution, no Seq bump.
	c := findPhoto(t, db, "physical-photos", "/holidays/c.jpg")
	require.NotNil(t, c)
	assert.Equal(t, int64(100), c.Seq)

	// D: version advanced without a Seq bump (same Place re-resolved).
	d := waitForPhotoState(t, db, "physical-photos", "/holidays/d.jpg",
		func(p *gallery.GalleryPhoto) bool { return p.GeoVersion == geo.Version },
		"version advanced for the same place")
	assert.Equal(t, int64(100), d.Seq, "an unchanged Place must not bump Seq")
	assert.True(t, math.Abs(*d.Lat-38.7223) < 1e-3)
}
