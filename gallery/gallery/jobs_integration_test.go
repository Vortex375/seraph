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
	"sync"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/gallery/gallery"
	"umbasa.net/seraph/gallery/gallery/gallerytest"
)

// jobWatcher records every JobEvent published on seraph.jobs.> per key.
type jobWatcher struct {
	mu     sync.Mutex
	events map[string][]events.JobEvent
}

func watchJobs(t *testing.T, nc *nats.Conn) *jobWatcher {
	t.Helper()
	w := &jobWatcher{events: map[string][]events.JobEvent{}}
	sub, err := nc.Subscribe("seraph.jobs.>", func(msg *nats.Msg) {
		ev := events.JobEvent{}
		if err := ev.Unmarshal(msg.Data); err != nil {
			return
		}
		w.mu.Lock()
		w.events[ev.Key] = append(w.events[ev.Key], ev)
		w.mu.Unlock()
	})
	require.NoError(t, err)
	require.NoError(t, nc.Flush())
	t.Cleanup(func() { sub.Unsubscribe() })
	return w
}

func (w *jobWatcher) all(key string) []events.JobEvent {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]events.JobEvent(nil), w.events[key]...)
}

// waitState waits until the last event under key has the given state and
// returns it.
func (w *jobWatcher) waitState(t *testing.T, key, state string) events.JobEvent {
	t.Helper()
	var last events.JobEvent
	waitForCondition(t, func() bool {
		evs := w.all(key)
		if len(evs) == 0 {
			return false
		}
		last = evs[len(evs)-1]
		return last.State == state
	}, "job "+key+" never reached state "+state)
	return last
}

func (w *jobWatcher) hasKey(key string) bool { return len(w.all(key)) > 0 }

func TestBackfillReportsJob(t *testing.T) {
	requireIntegration(t)

	provider, nc, db := getGalleryProvider(t)
	jobs := watchJobs(t, nc)
	subscribeSpaceResolve(t, nc, map[string][]string{"pino": {"photos"}})
	require.NoError(t, provider.Start())
	t.Cleanup(func() { provider.Stop(); nc.Close() })
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	stub := newStubFileIndex(t, nc, 2)
	stub.set("physical-photos", "/mounted/photos/holidays", withProvider("physical-photos", []events.FileIndexListEntry{
		fileEntry("/mounted/photos/holidays/a.jpg", 1, 1000, "image/jpeg"),
		fileEntry("/mounted/photos/holidays/b.jpg", 1, 1000, "image/jpeg"),
		fileEntry("/mounted/photos/holidays/c.jpg", 1, 1000, "image/jpeg"),
	}))

	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationAdd, UserId: "pino", SpaceProviderId: "photos", Path: "/holidays",
	})
	require.Equal(t, "", res.Error)

	last := jobs.waitState(t, "gallery.backfill."+res.SourceFolder[0].Id.Hex(), "completed")
	assert.Equal(t, int64(3), last.Done)
	assert.Contains(t, last.Description, "/holidays")
}

func TestRescanReportsJob(t *testing.T) {
	requireIntegration(t)

	provider, nc, db := getGalleryProvider(t)
	jobs := watchJobs(t, nc)
	subscribeSpaceResolve(t, nc, map[string][]string{"pino": {"photos"}})
	require.NoError(t, provider.Start())
	t.Cleanup(func() { provider.Stop(); nc.Close() })
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	dir := startFileProvider(t, "physical-photos")
	newStubFileIndexer(t, nc)
	writeFixture(t, dir, "/mounted/photos/holidays/a.jpg", gallerytest.BuildJPEGWithExif(t, 20, 15, "2016:02:02 02:02:02", 1))

	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationAdd, UserId: "pino", SpaceProviderId: "photos", Path: "/holidays",
	})
	require.Equal(t, "", res.Error)
	id := res.SourceFolder[0].Id
	require.Equal(t, "", rescan(t, nc, "pino", id.Hex()).Error)

	jobs.waitState(t, "gallery.rescan."+id.Hex(), "completed")
}

func TestRescanOfUnreachableProviderReportsFailed(t *testing.T) {
	requireIntegration(t)

	provider, nc, db := getGalleryProvider(t)
	jobs := watchJobs(t, nc)
	subscribeSpaceResolve(t, nc, map[string][]string{"pino": {"photos"}})
	require.NoError(t, provider.Start())
	t.Cleanup(func() { provider.Stop(); nc.Close() })
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	// no File Provider is started for physical-photos
	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationAdd, UserId: "pino", SpaceProviderId: "photos", Path: "/holidays",
	})
	require.Equal(t, "", res.Error)
	id := res.SourceFolder[0].Id
	require.Equal(t, "", rescan(t, nc, "pino", id.Hex()).Error)

	last := jobs.waitState(t, "gallery.rescan."+id.Hex(), "failed")
	assert.NotEmpty(t, last.StatusMessage)
}

func TestIngestQueueJobIsIdleWhenDrained(t *testing.T) {
	requireIntegration(t)

	provider, nc, _ := getGalleryProvider(t)
	// start from an empty queue: earlier tests leave file-change events behind
	js, err := jetstream.New(nc)
	require.NoError(t, err)
	_ = js.DeleteStream(context.Background(), events.FileChangedStream)
	jobs := watchJobs(t, nc)
	subscribeSpaceResolve(t, nc, map[string][]string{"pino": {"photos"}})
	require.NoError(t, provider.Start())
	t.Cleanup(func() { provider.Stop(); nc.Close() })

	last := jobs.waitState(t, "gallery.ingest", "idle")
	assert.Equal(t, int64(0), last.Pending)
}

func TestMetadataJobCountsDoneAndSkipped(t *testing.T) {
	requireIntegration(t)

	provider, nc, db := getGalleryProvider(t)
	jobs := watchJobs(t, nc)
	subscribeSpaceResolve(t, nc, map[string][]string{"pino": {"photos"}})
	require.NoError(t, provider.Start())
	t.Cleanup(func() { provider.Stop(); nc.Close() })
	clearPhotos(t, db)

	dir := startFileProvider(t, "physical-photos")
	data := gallerytest.BuildJPEGWithExif(t, 20, 15, "2016:02:02 02:02:02", 1)
	writeFixture(t, dir, "/mounted/photos/a.jpg", data)
	writeFixture(t, dir, "/mounted/photos/b.jpg", data)
	for _, p := range []string{"a", "b", "missing"} { // "missing" has no file: extraction fails
		_, err := db.Collection("galleryPhotos").InsertOne(context.Background(), bson.M{
			"providerId": "physical-photos", "path": "/mounted/photos/" + p + ".jpg", "deleted": false,
			"metadataPending": true, "capturedAt": int64(0), "capturedAtSource": "modtime", "unsupported": "",
		})
		require.NoError(t, err)
	}

	folderId := primitive.NewObjectID()
	require.NoError(t, provider.HealPendingMetadata(context.Background(), folderId, "physical-photos", "/mounted/photos"))

	key := "gallery.metadata." + folderId.Hex()
	last := jobs.waitState(t, key, "completed")
	evs := jobs.all(key)
	assert.Equal(t, "running", evs[0].State)
	assert.Equal(t, int64(0), evs[0].Done)
	assert.Equal(t, int64(3), evs[0].Total)
	assert.Equal(t, int64(3), last.Done)
	assert.Contains(t, last.StatusMessage, "1 skipped")
}

func TestMetadataJobAbsentWhenNothingPending(t *testing.T) {
	requireIntegration(t)

	provider, nc, db := getGalleryProvider(t)
	jobs := watchJobs(t, nc)
	subscribeSpaceResolve(t, nc, map[string][]string{"pino": {"photos"}})
	require.NoError(t, provider.Start())
	t.Cleanup(func() { provider.Stop(); nc.Close() })
	clearPhotos(t, db)

	folderId := primitive.NewObjectID()
	require.NoError(t, provider.HealPendingMetadata(context.Background(), folderId, "physical-photos", "/mounted/photos"))
	time.Sleep(300 * time.Millisecond)
	assert.False(t, jobs.hasKey("gallery.metadata."+folderId.Hex()))
}

func TestReplayReportsJob(t *testing.T) {
	requireIntegration(t)
	enableAI(t)
	db := resetReplay(t)
	seedReplayPhoto(t, db, "/a.jpg", 1, false)
	seedReplayPhoto(t, db, "/b.jpg", 2, false)
	seedReplayPhoto(t, db, "/gone.jpg", 3, true)

	provider, nc, _ := getGalleryProvider(t)
	jobs := watchJobs(t, nc)
	require.NoError(t, provider.Start())
	t.Cleanup(func() { provider.Stop(); nc.Close() })

	last := jobs.waitState(t, "gallery.replay", "completed")
	assert.Equal(t, int64(2), last.Done)
	assert.Equal(t, int64(2), last.Total)
	assert.Equal(t, int64(0), jobs.all("gallery.replay")[0].Done)
}

func TestReplayJobFailsOnPublishFailure(t *testing.T) {
	requireIntegration(t)
	enableAI(t)
	db := resetReplay(t)

	provider, nc, _ := getGalleryProvider(t)
	require.NoError(t, provider.Start())
	t.Cleanup(func() { provider.Stop(); nc.Close() })
	waitReplayDone(t, db) // empty replay finished

	seedReplayPhoto(t, db, "/a.jpg", 1, false)
	_, err := db.Collection("gallerySequenceCounters").DeleteOne(context.Background(), bson.M{"_id": "photoReplay"})
	require.NoError(t, err)
	js, err := jetstream.New(nc)
	require.NoError(t, err)
	require.NoError(t, js.DeleteStream(context.Background(), events.GalleryPhotoChangedStream))

	jobs := watchJobs(t, nc)
	require.Error(t, provider.RunPhotoReplay(context.Background()))
	last := jobs.waitState(t, "gallery.replay", "failed")
	assert.NotEmpty(t, last.StatusMessage)

	// restore the stream for the tests that follow
	_, err = js.CreateStream(context.Background(), jetstream.StreamConfig{
		Name:      events.GalleryPhotoChangedStream,
		Subjects:  []string{events.GalleryPhotoChangedTopic},
		Retention: jetstream.WorkQueuePolicy,
	})
	require.NoError(t, err)
}
