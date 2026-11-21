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
	"testing"
	"time"

	"github.com/nats-io/nats.go/jetstream"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"umbasa.net/seraph/events"
)

func seedReplayPhoto(t *testing.T, db *mongo.Database, path string, seq int64, deleted bool) primitive.ObjectID {
	t.Helper()
	res, err := db.Collection("galleryPhotos").InsertOne(context.Background(), bson.M{
		"providerId": "physical-photos", "path": path, "seq": seq, "deleted": deleted,
		"capturedAt": int64(0), "capturedAtSource": "indexed", "unsupported": "",
	})
	require.NoError(t, err)
	return res.InsertedID.(primitive.ObjectID)
}

func replayMarker(t *testing.T, db *mongo.Database) (bson.M, bool) {
	t.Helper()
	m := bson.M{}
	err := db.Collection("gallerySequenceCounters").FindOne(context.Background(), bson.M{"_id": "photoReplay"}).Decode(&m)
	if err == mongo.ErrNoDocuments {
		return nil, false
	}
	require.NoError(t, err)
	return m, true
}

func waitReplayDone(t *testing.T, db *mongo.Database) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if m, ok := replayMarker(t, db); ok && m["done"] == true {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("photo replay did not finish")
}

// startReplay seeds nothing itself: it starts a provider over the current
// database state (with a fresh watcher) and returns the watcher.
func startReplay(t *testing.T) (*changeWatcher, *mongo.Database, func()) {
	t.Helper()
	provider, nc, db := getGalleryProvider(t)
	w := watchPhotoChanged(t, nc)
	subscribeSpaceResolve(t, nc, map[string][]string{"pino": {"photos"}})
	require.NoError(t, provider.Start())
	stop := func() { provider.Stop(); nc.Close() }
	t.Cleanup(stop)
	return w, db, stop
}

func resetReplay(t *testing.T) *mongo.Database {
	t.Helper()
	_, _, db := getGalleryProvider(t)
	clearSourceFolders(t, db)
	clearPhotos(t, db)
	_, err := db.Collection("gallerySequenceCounters").DeleteOne(context.Background(), bson.M{"_id": "photoReplay"})
	require.NoError(t, err)
	return db
}

func TestPhotoReplayPublishesNonDeletedOnceThenNothingOnRestart(t *testing.T) {
	requireIntegration(t)
	enableAI(t)
	db := resetReplay(t)
	seedReplayPhoto(t, db, "/a.jpg", 7, false)
	seedReplayPhoto(t, db, "/gone.jpg", 8, true)
	seedReplayPhoto(t, db, "/b.jpg", 9, false)

	w, _, stop := startReplay(t)
	waitReplayDone(t, db)
	time.Sleep(300 * time.Millisecond)

	got := w.snapshot()
	require.Len(t, got, 2)
	assert.Equal(t, "/a.jpg", got[0].Path)
	assert.Equal(t, int64(7), got[0].Seq)
	assert.Equal(t, "upserted", got[0].Change)
	assert.Equal(t, "/b.jpg", got[1].Path)
	assert.Equal(t, int64(9), got[1].Seq)
	assert.Empty(t, w.forPath("/gone.jpg"))

	// done: a restart publishes nothing
	stop()
	w2, _, _ := startReplay(t)
	time.Sleep(500 * time.Millisecond)
	assert.Empty(t, w2.snapshot())

	// deleting the marker replays again
	_, err := db.Collection("gallerySequenceCounters").DeleteOne(context.Background(), bson.M{"_id": "photoReplay"})
	require.NoError(t, err)
	w3, _, _ := startReplay(t)
	waitReplayDone(t, db)
	time.Sleep(300 * time.Millisecond)
	assert.Len(t, w3.snapshot(), 2)
}

func TestPhotoReplayResumesAfterLastId(t *testing.T) {
	requireIntegration(t)
	enableAI(t)
	db := resetReplay(t)
	seedReplayPhoto(t, db, "/a.jpg", 1, false)
	b := seedReplayPhoto(t, db, "/b.jpg", 2, false)
	seedReplayPhoto(t, db, "/c.jpg", 3, false)
	_, err := db.Collection("gallerySequenceCounters").InsertOne(context.Background(),
		bson.M{"_id": "photoReplay", "lastId": b})
	require.NoError(t, err)

	w, _, _ := startReplay(t)
	waitReplayDone(t, db)
	time.Sleep(300 * time.Millisecond)

	got := w.snapshot()
	require.Len(t, got, 1)
	assert.Equal(t, "/c.jpg", got[0].Path)
}

func TestPhotoReplayDisabledPublishesNothingAndWritesNoMarker(t *testing.T) {
	requireIntegration(t)
	db := resetReplay(t)
	seedReplayPhoto(t, db, "/a.jpg", 1, false)

	w, _, _ := startReplay(t)
	time.Sleep(700 * time.Millisecond)

	assert.Empty(t, w.snapshot())
	_, ok := replayMarker(t, db)
	assert.False(t, ok)
}

func TestPhotoReplayDoesNotAdvancePastFailedPublish(t *testing.T) {
	requireIntegration(t)
	enableAI(t)
	db := resetReplay(t)

	provider, nc, _ := getGalleryProvider(t)
	require.NoError(t, provider.Start())
	t.Cleanup(func() { provider.Stop(); nc.Close() })
	waitReplayDone(t, db) // empty replay finished

	seedReplayPhoto(t, db, "/a.jpg", 1, false)
	seedReplayPhoto(t, db, "/b.jpg", 2, false)
	_, err := db.Collection("gallerySequenceCounters").DeleteOne(context.Background(), bson.M{"_id": "photoReplay"})
	require.NoError(t, err)

	js, err := jetstream.New(nc)
	require.NoError(t, err)
	require.NoError(t, js.DeleteStream(context.Background(), events.GalleryPhotoChangedStream))

	require.Error(t, provider.RunPhotoReplay(context.Background()))
	m, ok := replayMarker(t, db)
	if ok {
		assert.NotEqual(t, true, m["done"])
		assert.Nil(t, m["lastId"])
	}

	w := watchPhotoChanged(t, nc)
	_, err = js.CreateStream(context.Background(), jetstream.StreamConfig{
		Name:      events.GalleryPhotoChangedStream,
		Subjects:  []string{events.GalleryPhotoChangedTopic},
		Retention: jetstream.WorkQueuePolicy,
	})
	require.NoError(t, err)
	require.NoError(t, provider.RunPhotoReplay(context.Background()))
	waitReplayDone(t, db)
	time.Sleep(300 * time.Millisecond)
	assert.Len(t, w.snapshot(), 2)
}
