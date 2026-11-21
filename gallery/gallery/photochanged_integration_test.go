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
	"encoding/json"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.mongodb.org/mongo-driver/bson"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/gallery/gallery"
)

// changeWatcher records every GalleryPhotoChangedEvent seen on
// events.GalleryPhotoChangedTopic via a plain core-NATS subscription (a
// JetStream publish is an ordinary publish on the wire, like warmWatcher).
type changeWatcher struct {
	mu     sync.Mutex
	events []events.GalleryPhotoChangedEvent
}

func watchPhotoChanged(t *testing.T, nc *nats.Conn) *changeWatcher {
	t.Helper()

	w := &changeWatcher{}
	sub, err := nc.Subscribe(events.GalleryPhotoChangedTopic, func(msg *nats.Msg) {
		ev := events.GalleryPhotoChangedEvent{}
		if err := json.Unmarshal(msg.Data, &ev); err != nil {
			return
		}
		w.mu.Lock()
		w.events = append(w.events, ev)
		w.mu.Unlock()
	})
	require.NoError(t, err)
	t.Cleanup(func() { sub.Unsubscribe() })
	require.NoError(t, nc.Flush())
	return w
}

func (w *changeWatcher) snapshot() []events.GalleryPhotoChangedEvent {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]events.GalleryPhotoChangedEvent(nil), w.events...)
}

// forPath returns the events observed for one physical path.
func (w *changeWatcher) forPath(path string) []events.GalleryPhotoChangedEvent {
	var out []events.GalleryPhotoChangedEvent
	for _, ev := range w.snapshot() {
		if ev.Path == path {
			out = append(out, ev)
		}
	}
	return out
}

func (w *changeWatcher) waitForPath(t *testing.T, path string, n int) []events.GalleryPhotoChangedEvent {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if got := w.forPath(path); len(got) >= n {
			return got
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("expected at least %d GalleryPhotoChangedEvents for %s, got %d", n, path, len(w.forPath(path)))
	return nil
}

func addHolidaysFolder(t *testing.T, nc *nats.Conn) {
	t.Helper()
	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	require.Equal(t, "", res.Error)
}

func TestPhotoChangedUpsertedOnCreateCarriesStoredSeq(t *testing.T) {
	requireIntegration(t)
	enableAI(t)

	nc, db := startGalleryProvider(t, map[string][]string{"pino": {"photos"}})
	clearSourceFolders(t, db)
	clearPhotos(t, db)
	w := watchPhotoChanged(t, nc)
	dir := startFileProvider(t, "physical-photos")
	addHolidaysFolder(t, nc)

	data := gallerytest.BuildJPEGWithExif(t, 40, 30, "2019:06:15 10:20:30", 1)
	physicalPath := "/mounted/photos/holidays/created.jpg"
	writeFixture(t, dir, physicalPath, data)
	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")

	photo := waitForPhoto(t, db, "physical-photos", physicalPath)
	got := w.waitForPath(t, physicalPath, 1)

	assert.Equal(t, []events.GalleryPhotoChangedEvent{{
		ProviderID: "physical-photos",
		Path:       physicalPath,
		Change:     events.GalleryPhotoUpserted,
		Seq:        photo.Seq,
	}}, got)
	assert.Greater(t, photo.Seq, int64(0))

	// the stream was declared as a work queue
	js, err := jetstream.New(nc)
	require.NoError(t, err)
	stream, err := js.Stream(context.Background(), events.GalleryPhotoChangedStream)
	require.NoError(t, err)
	assert.Equal(t, jetstream.WorkQueuePolicy, stream.CachedInfo().Config.Retention)
}

func TestPhotoChangedUpsertedOnChangeCarriesNewSeq(t *testing.T) {
	requireIntegration(t)
	enableAI(t)

	nc, db := startGalleryProvider(t, map[string][]string{"pino": {"photos"}})
	clearSourceFolders(t, db)
	clearPhotos(t, db)
	w := watchPhotoChanged(t, nc)
	dir := startFileProvider(t, "physical-photos")
	addHolidaysFolder(t, nc)

	physicalPath := "/mounted/photos/holidays/changed.jpg"
	data := gallerytest.BuildJPEGWithExif(t, 40, 30, "2019:06:15 10:20:30", 1)
	writeFixture(t, dir, physicalPath, data)
	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")
	first := w.waitForPath(t, physicalPath, 1)[0]

	data2 := gallerytest.BuildJPEGWithExif(t, 80, 60, "2019:06:15 10:20:30", 1)
	writeFixture(t, dir, physicalPath, data2)
	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventChanged, int64(len(data2)), time.Now().Unix(), "image/jpeg")
	got := w.waitForPath(t, physicalPath, 2)

	second := got[1]
	assert.Equal(t, events.GalleryPhotoUpserted, second.Change)
	assert.Greater(t, second.Seq, first.Seq)
	photo := waitForPhotoState(t, db, "physical-photos", physicalPath,
		func(p *gallery.GalleryPhoto) bool { return p.Seq == second.Seq }, "stored seq equals the published seq")
	assert.Equal(t, 80, photo.Width)
}

func TestPhotoChangedDeletedCarriesNewSeq(t *testing.T) {
	requireIntegration(t)
	enableAI(t)

	nc, db := startGalleryProvider(t, map[string][]string{"pino": {"photos"}})
	clearSourceFolders(t, db)
	clearPhotos(t, db)
	w := watchPhotoChanged(t, nc)
	dir := startFileProvider(t, "physical-photos")
	addHolidaysFolder(t, nc)

	physicalPath := "/mounted/photos/holidays/gone.jpg"
	data := gallerytest.BuildJPEGWithExif(t, 12, 8, "2018:05:05 08:00:00", 0)
	writeFixture(t, dir, physicalPath, data)
	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")
	first := w.waitForPath(t, physicalPath, 1)[0]

	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventDeleted, 0, 0, "")
	got := w.waitForPath(t, physicalPath, 2)

	assert.Equal(t, events.GalleryPhotoDeleted, got[1].Change)
	assert.Equal(t, "physical-photos", got[1].ProviderID)
	assert.Greater(t, got[1].Seq, first.Seq)
	photo := waitForPhotoState(t, db, "physical-photos", physicalPath,
		func(p *gallery.GalleryPhoto) bool { return p.Deleted }, "tombstoned")
	assert.Equal(t, photo.Seq, got[1].Seq)
}

func TestPhotoChangedDeletedOnFileGoneFallback(t *testing.T) {
	requireIntegration(t)
	enableAI(t)

	nc, db := startGalleryProvider(t, map[string][]string{"pino": {"photos"}})
	clearSourceFolders(t, db)
	clearPhotos(t, db)
	w := watchPhotoChanged(t, nc)
	startFileProvider(t, "physical-photos")
	addHolidaysFolder(t, nc)

	physicalPath := "/mounted/photos/holidays/moved-away.jpg"
	_, err := db.Collection("galleryPhotos").InsertOne(context.Background(), bson.M{
		"providerId": "physical-photos",
		"path":       physicalPath,
		"capturedAt": int64(1600000000),
		"size":       int64(100),
		"mime":       "image/jpeg",
		"seq":        int64(0),
	})
	require.NoError(t, err)

	// never written to disk
	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventChanged, 100, time.Now().Unix(), "image/jpeg")

	got := w.waitForPath(t, physicalPath, 1)
	assert.Equal(t, events.GalleryPhotoDeleted, got[0].Change)
	photo := waitForPhotoState(t, db, "physical-photos", physicalPath,
		func(p *gallery.GalleryPhoto) bool { return p.Deleted }, "tombstoned")
	assert.Equal(t, photo.Seq, got[0].Seq)
	assert.Greater(t, got[0].Seq, int64(0))
}

func TestPhotoChangedBackfillPublishesOnlyForInsertedRows(t *testing.T) {
	requireIntegration(t)
	enableAI(t)

	nc, db := startGalleryProvider(t, map[string][]string{"pino": {"photos"}})
	clearSourceFolders(t, db)
	clearPhotos(t, db)
	w := watchPhotoChanged(t, nc)

	physicalPath := "/mounted/photos/holidays/2024/shared.jpg"
	entry := fileEntry(physicalPath, 1024, time.Now().Unix(), "image/jpeg")
	stub := newStubFileIndex(t, nc, 10)
	stub.set("physical-photos", "/mounted/photos/holidays", withProvider("physical-photos", []events.FileIndexListEntry{entry}))
	stub.set("physical-photos", "/mounted/photos/holidays/2024", withProvider("physical-photos", []events.FileIndexListEntry{entry}))

	addHolidaysFolder(t, nc)
	photo := waitForPhoto(t, db, "physical-photos", physicalPath)
	got := w.waitForPath(t, physicalPath, 1)
	assert.Equal(t, events.GalleryPhotoUpserted, got[0].Change)
	assert.Equal(t, photo.Seq, got[0].Seq)

	// the nested folder's backfill re-walks the same file: a no-op, so silent
	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays/2024",
	})
	require.Equal(t, "", res.Error)
	time.Sleep(500 * time.Millisecond)
	assert.Len(t, w.forPath(physicalPath), 1)
}

func TestPhotoChangedMetadataSweepPublishesNothing(t *testing.T) {
	requireIntegration(t)
	enableAI(t)

	provider, nc, db := getGalleryProvider(t)
	dir := startFileProvider(t, "physical-photos")
	subscribeSpaceResolve(t, nc, map[string][]string{"pino": {"photos"}})
	w := watchPhotoChanged(t, nc)
	clearPhotos(t, db)
	writeFixture(t, dir, "/holidays/sweep-me.jpg", exifLisbonJPEG(t))
	insertStalePhoto(t, db, "physical-photos", "/holidays/sweep-me.jpg", nil)
	require.NoError(t, provider.Start())
	t.Cleanup(func() {
		provider.Stop()
		nc.Close()
	})

	// the sweep really ran (and bumped seq)...
	waitForPhotoState(t, db, "physical-photos", "/holidays/sweep-me.jpg",
		func(p *gallery.GalleryPhoto) bool { return p.MetadataVersion == 3 && p.Seq > 0 }, "swept")
	// ...yet published nothing
	time.Sleep(300 * time.Millisecond)
	assert.Empty(t, w.snapshot())
}

func TestPhotoChangedNothingPublishedWhenAIDisabled(t *testing.T) {
	requireIntegration(t)

	nc, db := startGalleryProvider(t, map[string][]string{"pino": {"photos"}})
	clearSourceFolders(t, db)
	clearPhotos(t, db)
	w := watchPhotoChanged(t, nc)
	dir := startFileProvider(t, "physical-photos")

	stub := newStubFileIndex(t, nc, 10)
	backfilled := fileEntry("/mounted/photos/holidays/backfilled.jpg", 1024, time.Now().Unix(), "image/jpeg")
	stub.set("physical-photos", "/mounted/photos/holidays", withProvider("physical-photos", []events.FileIndexListEntry{backfilled}))
	addHolidaysFolder(t, nc)
	waitForPhoto(t, db, "physical-photos", backfilled.Path)

	livePath := "/mounted/photos/holidays/live.jpg"
	data := gallerytest.BuildJPEGWithExif(t, 12, 8, "2018:05:05 08:00:00", 0)
	writeFixture(t, dir, livePath, data)
	publishFileChanged(t, nc, "physical-photos", livePath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")
	waitForPhoto(t, db, "physical-photos", livePath)
	publishFileChanged(t, nc, "physical-photos", livePath, events.FileChangedEventDeleted, 0, 0, "")
	waitForPhotoState(t, db, "physical-photos", livePath,
		func(p *gallery.GalleryPhoto) bool { return p.Deleted }, "tombstoned")

	time.Sleep(300 * time.Millisecond)
	assert.Empty(t, w.snapshot(), "ai.enabled is off: nothing may be published")
}

func TestPhotoChangedPublishFailureDoesNotFailIngestion(t *testing.T) {
	requireIntegration(t)
	enableAI(t)

	nc, db := startGalleryProvider(t, map[string][]string{"pino": {"photos"}})
	clearSourceFolders(t, db)
	clearPhotos(t, db)
	dir := startFileProvider(t, "physical-photos")
	addHolidaysFolder(t, nc)

	// remove the stream and have no subscriber, so every publish fails
	js, err := jetstream.New(nc)
	require.NoError(t, err)
	require.NoError(t, js.DeleteStream(context.Background(), events.GalleryPhotoChangedStream))

	physicalPath := fmt.Sprintf("/mounted/photos/holidays/publish-fails-%d.jpg", time.Now().UnixNano())
	data := gallerytest.BuildJPEGWithExif(t, 12, 8, "2018:05:05 08:00:00", 0)
	writeFixture(t, dir, physicalPath, data)
	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")

	photo := waitForPhoto(t, db, "physical-photos", physicalPath)
	assert.False(t, photo.Deleted)
	assert.Greater(t, photo.Seq, int64(0))
}
