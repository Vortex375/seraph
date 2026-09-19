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
	"context"
	"fmt"
	"log/slog"
	"os"
	"path"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/gallery/gallery"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/tracing"
)

// startFileProvider brings up a real fileprovider.FileProviderServer backed
// by a temp directory, on the shared embedded NATS server. Tests write
// fixture bytes into the returned directory before publishing a
// FileChangedEvent that references them, so metadata extraction goes
// through the same File Provider request/reply path the real service uses -
// no gallery-internal seam is stubbed.
func startFileProvider(t *testing.T, providerId string) string {
	t.Helper()

	dir, err := os.MkdirTemp("", "seraph-gallery-test-")
	require.NoError(t, err)
	t.Cleanup(func() { os.RemoveAll(dir) })

	nc, err := nats.Connect(natsServer.ClientURL())
	require.NoError(t, err)
	t.Cleanup(func() { nc.Close() })

	logger := logging.New(logging.Params{})
	logger.SetLevel(slog.LevelDebug)

	srv, err := fileprovider.NewFileProviderServer(fileprovider.ServerParams{
		Nc:      nc,
		Tracing: tracing.NewNoopTracing(),
		Logger:  logger,
	}, providerId, webdav.Dir(dir), true)
	require.NoError(t, err)
	require.NoError(t, srv.Start())
	t.Cleanup(func() { srv.Stop(true) })

	return dir
}

// publishFileChanged publishes a FileChangedEvent for (providerId, path) on
// the durable file-change stream the gallery service consumes, exactly as
// file-indexer does in production.
func publishFileChanged(t *testing.T, nc *nats.Conn, providerId, filePath, change string, size int64, modTime int64, mime string) {
	t.Helper()

	ev := events.FileChangedEvent{
		Event:      events.Event{ID: uuid.NewString(), Version: 1},
		FileID:     uuid.NewString(),
		ProviderID: providerId,
		Change:     change,
		Path:       filePath,
		Size:       size,
		ModTime:    modTime,
		Mime:       mime,
	}
	data, err := ev.Marshal()
	require.NoError(t, err)

	topic := fmt.Sprintf(events.FileChangedTopicPattern, ev.FileID)
	require.NoError(t, nc.Publish(topic, data))
	require.NoError(t, nc.Flush())
}

func findPhoto(t *testing.T, db *mongo.Database, providerId, filePath string) *gallery.GalleryPhoto {
	t.Helper()
	var photo gallery.GalleryPhoto
	err := db.Collection("galleryPhotos").FindOne(context.Background(), bson.M{
		"providerId": providerId,
		"path":       filePath,
	}).Decode(&photo)
	if err == mongo.ErrNoDocuments {
		return nil
	}
	require.NoError(t, err)
	return &photo
}

// waitForPhoto polls until a galleryPhotos document appears for
// (providerId, path) or the deadline passes. Ingestion is asynchronous
// (durable JetStream consumer, background goroutines), so tests need to wait
// rather than assert immediately after publish.
func waitForPhoto(t *testing.T, db *mongo.Database, providerId, filePath string) *gallery.GalleryPhoto {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if photo := findPhoto(t, db, providerId, filePath); photo != nil {
			return photo
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("gallery photo for %s/%s did not appear within the deadline", providerId, filePath)
	return nil
}

// waitForCondition polls cond until it returns true or the deadline passes,
// failing the test otherwise. Used for negative assertions (e.g. "still
// absent after settling") together with a fixed settle delay, and for
// waiting on state changes that aren't "a document exists".
func waitForCondition(t *testing.T, cond func() bool, msg string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal(msg)
}

func clearPhotos(t *testing.T, db *mongo.Database) {
	t.Helper()
	_, err := db.Collection("galleryPhotos").DeleteMany(context.Background(), bson.M{})
	require.NoError(t, err)
}

// TestPhotoWithExifCaptureDateIsIngested covers: a photo appearing in a
// configured folder is ingested with Capture Date read from its own EXIF
// DateTimeOriginal, pixel dimensions and orientation recorded, and the
// source of the date recorded as "exif".
func TestPhotoWithExifCaptureDateIsIngested(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	dir := startFileProvider(t, "physical-photos")

	// configure the folder - resolves to physical "/mounted/photos" per the
	// stub spaces resolver in startGalleryProvider
	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	assert.Equal(t, "", res.Error)

	captureTime := time.Date(2019, 6, 15, 10, 20, 30, 0, time.UTC)
	data := buildJPEGWithExif(t, 40, 30, "2019:06:15 10:20:30", 6)
	physicalPath := "/mounted/photos/holidays/beach.jpg"
	writeFixture(t, dir, physicalPath, data)

	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")

	photo := waitForPhoto(t, db, "physical-photos", physicalPath)

	assert.Equal(t, captureTime.Unix(), photo.CapturedAt)
	assert.Equal(t, gallery.CaptureDateSourceExif, photo.CapturedAtSource)
	assert.Equal(t, 40, photo.Width)
	assert.Equal(t, 30, photo.Height)
	assert.Equal(t, 6, photo.Orientation)
	assert.Equal(t, "", photo.Unsupported)
	assert.False(t, photo.Deleted)
}

// TestPhotoWithoutExifFallsBackToModTime covers the second rung of the
// Capture Date fallback chain, and that modification time is recorded as
// what it is (a fallback, not a real capture date) via CapturedAtSource.
func TestPhotoWithoutExifFallsBackToModTime(t *testing.T) {
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

	// PNG carries no EXIF at all
	data := buildPNG(t, 20, 10)
	physicalPath := "/mounted/photos/holidays/screenshot.png"
	writeFixture(t, dir, physicalPath, data)

	modTime := time.Date(2020, 3, 1, 0, 0, 0, 0, time.UTC).Unix()
	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventCreated, int64(len(data)), modTime, "image/png")

	photo := waitForPhoto(t, db, "physical-photos", physicalPath)

	assert.Equal(t, modTime, photo.CapturedAt)
	assert.Equal(t, gallery.CaptureDateSourceModTime, photo.CapturedAtSource)
	assert.Equal(t, 20, photo.Width)
	assert.Equal(t, 10, photo.Height)
}

// TestPhotoWithoutExifOrModTimeFallsBackToIndexedTime covers the third and
// final rung: when even modification time is unusable (zero / not carried),
// Capture Date falls back to the time the item was first indexed rather than
// being rejected.
func TestPhotoWithoutExifOrModTimeFallsBackToIndexedTime(t *testing.T) {
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

	data := buildPNG(t, 20, 10)
	physicalPath := "/mounted/photos/holidays/noexif.png"
	writeFixture(t, dir, physicalPath, data)

	before := time.Now().Unix()
	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventCreated, int64(len(data)), 0, "image/png")

	photo := waitForPhoto(t, db, "physical-photos", physicalPath)
	after := time.Now().Unix()

	assert.Equal(t, gallery.CaptureDateSourceIndexed, photo.CapturedAtSource)
	assert.GreaterOrEqual(t, photo.CapturedAt, before)
	assert.LessOrEqual(t, photo.CapturedAt, after)
}

// TestNonsensicalExifDateIsStoredNotRejected covers the requirement that a
// photo with an implausible embedded date is still stored, at rung one,
// rather than being treated as invalid and falling through to a later rung.
func TestNonsensicalExifDateIsStoredNotRejected(t *testing.T) {
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

	// year 1902: a sensor-default-looking, implausible date, but a
	// perfectly well-formed EXIF tag
	data := buildJPEGWithExif(t, 10, 10, "1902:01:01 00:00:00", 0)
	physicalPath := "/mounted/photos/holidays/weird.jpg"
	writeFixture(t, dir, physicalPath, data)

	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")

	photo := waitForPhoto(t, db, "physical-photos", physicalPath)

	assert.Equal(t, gallery.CaptureDateSourceExif, photo.CapturedAtSource)
	assert.Equal(t, time.Date(1902, 1, 1, 0, 0, 0, 0, time.UTC).Unix(), photo.CapturedAt)
}

// TestUndecodableFileIsStoredAsUnsupported covers: a file the service cannot
// decode (not a recognized image format) is recorded with an "unsupported"
// reason and still stored - it must still appear, not be omitted.
func TestUndecodableFileIsStoredAsUnsupported(t *testing.T) {
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

	// not an image at all (simulates e.g. a RAW file Go's stdlib can't
	// decode)
	data := []byte("this is not an image, just plain bytes pretending to be a RAW file")
	physicalPath := "/mounted/photos/holidays/raw.arw"
	writeFixture(t, dir, physicalPath, data)

	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "application/octet-stream")

	photo := waitForPhoto(t, db, "physical-photos", physicalPath)

	assert.Equal(t, gallery.UnsupportedReasonFormat, photo.Unsupported)
	// still gets a Capture Date via the fallback chain - display support and
	// backup/listing coverage are independent
	assert.NotEqual(t, "", photo.CapturedAtSource)
}

// TestCorruptFileFailsAloneWithoutStoppingOthers covers: a corrupt/truncated
// file fails for that item alone and does not stop the rest of the folder
// from loading - a good file published alongside a bad one still ingests.
func TestCorruptFileFailsAloneWithoutStoppingOthers(t *testing.T) {
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

	// a truncated JPEG: valid SOI marker, then nothing - image.DecodeConfig
	// will fail with an unexpected-EOF-style error, not image.ErrFormat
	corrupt := []byte{0xFF, 0xD8, 0xFF}
	corruptPath := "/mounted/photos/holidays/truncated.jpg"
	writeFixture(t, dir, corruptPath, corrupt)

	good := buildJPEGWithExif(t, 12, 8, "2021:01:01 12:00:00", 1)
	goodPath := "/mounted/photos/holidays/good.jpg"
	writeFixture(t, dir, goodPath, good)

	publishFileChanged(t, nc, "physical-photos", corruptPath, events.FileChangedEventCreated, int64(len(corrupt)), time.Now().Unix(), "image/jpeg")
	publishFileChanged(t, nc, "physical-photos", goodPath, events.FileChangedEventCreated, int64(len(good)), time.Now().Unix(), "image/jpeg")

	// the good file must ingest regardless of the corrupt one
	goodPhoto := waitForPhoto(t, db, "physical-photos", goodPath)
	assert.Equal(t, "", goodPhoto.Unsupported)

	// the corrupt file is stored too, marked unsupported/corrupt - it must
	// not be silently dropped either
	corruptPhoto := waitForPhoto(t, db, "physical-photos", corruptPath)
	assert.Equal(t, gallery.UnsupportedReasonCorrupt, corruptPhoto.Unsupported)
}

// TestDeletedEventRemovesPhotoFromListing covers: a "deleted" event removes
// the photo. The read model marks it deleted rather than dropping the row,
// so this is observed as findPhoto still finding a document, but with
// Deleted set.
func TestDeletedEventRemovesPhotoFromListing(t *testing.T) {
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

	data := buildJPEGWithExif(t, 12, 8, "2018:05:05 08:00:00", 0)
	physicalPath := "/mounted/photos/holidays/gone.jpg"
	writeFixture(t, dir, physicalPath, data)

	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")
	photo := waitForPhoto(t, db, "physical-photos", physicalPath)
	assert.False(t, photo.Deleted)

	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventDeleted, 0, 0, "")

	waitForCondition(t, func() bool {
		p := findPhoto(t, db, "physical-photos", physicalPath)
		return p != nil && p.Deleted
	}, "deleted photo was never marked deleted")
}

// TestSameFileArrivingTwiceProducesOneItem covers the upsert-on-physical-key
// requirement directly: two "created" events for the same (providerId, path)
// - e.g. a live event racing a hypothetical backfill - must yield exactly one
// document, not two.
func TestSameFileArrivingTwiceProducesOneItem(t *testing.T) {
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

	data := buildJPEGWithExif(t, 12, 8, "2018:05:05 08:00:00", 0)
	physicalPath := "/mounted/photos/holidays/twice.jpg"
	writeFixture(t, dir, physicalPath, data)

	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")
	waitForPhoto(t, db, "physical-photos", physicalPath)

	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventChanged, int64(len(data)), time.Now().Unix(), "image/jpeg")

	waitForCondition(t, func() bool {
		count, err := db.Collection("galleryPhotos").CountDocuments(context.Background(), bson.M{
			"providerId": "physical-photos",
			"path":       physicalPath,
		})
		require.NoError(t, err)
		return count == 1
	}, "expected exactly one document for the same physical file after two events")
}

// TestEventsOutsideConfiguredFoldersAreIgnored covers cheap rejection: an
// event for a path outside every configured folder must not produce a
// gallery item, and a folder named similarly (but not a real path prefix,
// e.g. "/Photos2" vs "/Photos") must not match either.
func TestEventsOutsideConfiguredFoldersAreIgnored(t *testing.T) {
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

	// outside the configured folder entirely
	data := buildJPEGWithExif(t, 12, 8, "2018:05:05 08:00:00", 0)
	outsidePath := "/mounted/photos/documents/scan.jpg"
	writeFixture(t, dir, outsidePath, data)
	publishFileChanged(t, nc, "physical-photos", outsidePath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")

	// a sibling folder that merely shares a string prefix, not a path prefix
	siblingPath := "/mounted/photos/holidays2/decoy.jpg"
	writeFixture(t, dir, siblingPath, data)
	publishFileChanged(t, nc, "physical-photos", siblingPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")

	// a real in-folder file, published last, so once it lands we know both
	// prior events have already been processed (or correctly ignored) by
	// the same sequential-per-provider consumer
	insidePath := "/mounted/photos/holidays/inside.jpg"
	writeFixture(t, dir, insidePath, data)
	publishFileChanged(t, nc, "physical-photos", insidePath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")

	waitForPhoto(t, db, "physical-photos", insidePath)

	assert.Nil(t, findPhoto(t, db, "physical-photos", outsidePath))
	assert.Nil(t, findPhoto(t, db, "physical-photos", siblingPath))
}

// TestDotfileEventsProduceNoPhoto covers: a Created or Changed event for a
// dotfile path under a configured Gallery Source Folder produces no
// galleryPhotos document, and a Deleted event for a dotfile path produces no
// document either - confirming the dotfile reject covers the delete branch as
// well as the create/change branch. A non-dotfile file under the same folder
// published alongside continues to ingest exactly as before.
func TestDotfileEventsProduceNoPhoto(t *testing.T) {
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

	data := buildJPEGWithExif(t, 12, 8, "2018:05:05 08:00:00", 0)

	// a Created event for a dotfile (e.g. a .DS_Store) under the folder
	dotfileCreatedPath := "/mounted/photos/holidays/.DS_Store"
	writeFixture(t, dir, dotfileCreatedPath, data)
	publishFileChanged(t, nc, "physical-photos", dotfileCreatedPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "application/octet-stream")

	// a Changed event for a different dotfile (e.g. an editor lock file)
	dotfileChangedPath := "/mounted/photos/holidays/.beach.jpg.swp"
	writeFixture(t, dir, dotfileChangedPath, data)
	publishFileChanged(t, nc, "physical-photos", dotfileChangedPath, events.FileChangedEventChanged, int64(len(data)), time.Now().Unix(), "application/octet-stream")

	// a Deleted event for a dotfile path - the filter must reject it before
	// markDeleted, so no document is ever created
	dotfileDeletedPath := "/mounted/photos/holidays/.gone.jpg.part"
	publishFileChanged(t, nc, "physical-photos", dotfileDeletedPath, events.FileChangedEventDeleted, 0, 0, "")

	// a real in-folder file published last, so once it lands we know the
	// dotfile events have already been processed (or correctly ignored) by
	// the same sequential-per-provider consumer
	insidePath := "/mounted/photos/holidays/beach.jpg"
	writeFixture(t, dir, insidePath, data)
	publishFileChanged(t, nc, "physical-photos", insidePath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")

	waitForPhoto(t, db, "physical-photos", insidePath)

	// give the dotfile events a chance to be processed and assert none of
	// them produced a document
	assert.Nil(t, findPhoto(t, db, "physical-photos", dotfileCreatedPath))
	assert.Nil(t, findPhoto(t, db, "physical-photos", dotfileChangedPath))
	assert.Nil(t, findPhoto(t, db, "physical-photos", dotfileDeletedPath))

	// and the non-dotfile file is present exactly as before
	photo := findPhoto(t, db, "physical-photos", insidePath)
	require.NotNil(t, photo)
	assert.False(t, photo.Deleted)
}

// TestTwoUsersSharingAFolderProduceOneReadModelDocument covers: the read
// model is shared across users while configuration stays per user - two
// users configuring the same physical folder cost one metadata extraction,
// observed as one document rather than two.
func TestTwoUsersSharingAFolderProduceOneReadModelDocument(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"family"},
		"lino": {"family"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	dir := startFileProvider(t, "physical-family")

	// both users configure the same space+path - resolving to the same
	// physical prefix ("/mounted/family") per the stub resolver
	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "family",
		Path:            "/",
	})
	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "lino",
		SpaceProviderId: "family",
		Path:            "/",
	})

	data := buildJPEGWithExif(t, 12, 8, "2022:02:02 02:02:02", 0)
	physicalPath := "/mounted/family/shared.jpg"
	writeFixture(t, dir, physicalPath, data)
	publishFileChanged(t, nc, "physical-family", physicalPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")

	waitForPhoto(t, db, "physical-family", physicalPath)

	count, err := db.Collection("galleryPhotos").CountDocuments(context.Background(), bson.M{
		"providerId": "physical-family",
		"path":       physicalPath,
	})
	require.NoError(t, err)
	assert.Equal(t, int64(1), count, "two users sharing a folder must cost exactly one read-model document")
}

// writeFixture writes data at relativePath under dir, creating parent
// directories as needed. relativePath is provider-relative (not
// space-relative), matching how startFileProvider's webdav.Dir root maps to
// the provider's own root.
func writeFixture(t *testing.T, dir string, relativePath string, data []byte) {
	t.Helper()
	full := path.Join(dir, relativePath)
	require.NoError(t, os.MkdirAll(path.Dir(full), 0777))
	require.NoError(t, os.WriteFile(full, data, 0666))
}
