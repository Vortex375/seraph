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

package fileindexer_test

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/spf13/viper"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.uber.org/fx/fxtest"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/file-indexer/fileindexer"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/mongodb"
	"umbasa.net/seraph/tracing"
)

// consumerTestEnv wires up a fresh embedded NATS server (so each test gets its
// own JetStream streams/durables/KV, avoiding cross-test durable-name
// collisions on the shared TestMain server) and a fresh mongo database, then
// starts a real fileindexer.Consumer against them.
type consumerTestEnv struct {
	nc   *nats.Conn
	js   jetstream.JetStream
	db   *mongo.Database
	cons fileindexer.Consumer
}

func setupConsumer(t *testing.T) *consumerTestEnv {
	t.Helper()

	natsSrv, nc := startNatsServer(t)
	t.Cleanup(func() {
		nc.Close()
		natsSrv.Shutdown()
	})

	js, err := jetstream.New(nc)
	require.NoError(t, err)

	dbName := fmt.Sprintf("file_indexer_test_%s", uniqueSuffix())

	localV := viper.New()
	localV.Set("mongo.url", mongoUrl)
	localV.Set("mongo.db", dbName)
	localV.Set("fileindexer.parallel", 8)

	migrations, err := fileindexer.NewMigrations(localV)
	require.NoError(t, err)

	res, err := mongodb.NewClient(mongodb.ClientParams{
		Viper:   localV,
		Tracing: tracing.NewNoopTracing(),
		Lc:      fxtest.NewLifecycle(t),
	})
	require.NoError(t, err)
	db := res.Client.Database(dbName)

	logger := logging.New(logging.Params{})
	logger.SetLevel(slog.LevelDebug)

	cons, err := fileindexer.NewConsumer(fileindexer.ConsumerParams{
		Nc:      nc,
		Js:      js,
		Db:      db,
		Logger:  logger,
		Viper:   localV,
		Tracing: tracing.NewNoopTracing(),
		Mig:     migrations,
	})
	require.NoError(t, err)
	require.NoError(t, cons.Start())
	t.Cleanup(cons.Stop)

	return &consumerTestEnv{nc: nc, js: js, db: db, cons: cons}
}

func startNatsServer(t *testing.T) (*server.Server, *nats.Conn) {
	t.Helper()

	storeDir, err := os.MkdirTemp("", "seraph-consumer-test-")
	require.NoError(t, err)
	t.Cleanup(func() { _ = os.RemoveAll(storeDir) })

	opts := &server.Options{
		Port:      server.RANDOM_PORT,
		JetStream: true,
		StoreDir:  storeDir,
	}
	natsSrv, err := server.NewServer(opts)
	require.NoError(t, err)
	natsSrv.Start()
	require.True(t, natsSrv.ReadyForConnections(10*time.Second), "embedded NATS server did not become ready")

	nc, err := nats.Connect(natsSrv.ClientURL())
	require.NoError(t, err)
	return natsSrv, nc
}

type seedFileSpec struct {
	id         primitive.ObjectID
	providerId string
	path       string
	parentDir  primitive.ObjectID
	isDir      bool
	size       int64
	mode       int64
	modTime    int64
	mime       string
}

func (e *consumerTestEnv) seedFiles(t *testing.T, files []seedFileSpec) {
	t.Helper()
	coll := e.db.Collection("files")
	docs := make([]any, 0, len(files))
	for _, f := range files {
		docs = append(docs, bson.M{
			"_id":        f.id,
			"providerId": f.providerId,
			"path":       f.path,
			"parentDir":  f.parentDir,
			"isDir":      f.isDir,
			"size":       f.size,
			"mode":       f.mode,
			"modTime":    f.modTime,
			"mime":       f.mime,
			"pending":    false,
		})
	}
	_, err := coll.InsertMany(context.Background(), docs)
	require.NoError(t, err)
}

func (e *consumerTestEnv) seedReaddir(t *testing.T, entries []fileindexer.Readdir) {
	t.Helper()
	coll := e.db.Collection("readdir")
	docs := make([]any, 0, len(entries))
	for _, r := range entries {
		docs = append(docs, bson.M{
			"readdir":   r.Readdir,
			"index":     r.Index,
			"total":     r.Total,
			"file":      r.File,
			"parentDir": r.ParentDir,
		})
	}
	_, err := coll.InsertMany(context.Background(), docs)
	require.NoError(t, err)
}

func (e *consumerTestEnv) publishRemoved(t *testing.T, providerId, removedPath string) {
	t.Helper()
	ev := events.FileRemovedEvent{
		Event: events.Event{
			ID:      uuid.NewString(),
			Version: 1,
		},
		ProviderID: providerId,
		Path:       removedPath,
	}
	data, err := ev.Marshal()
	require.NoError(t, err)
	require.NoError(t, e.nc.Publish(fmt.Sprintf(events.FileProviderFileRemovedTopicPattern, providerId), data))
}

// subscribeChanges returns a channel carrying every FileChangedEvent the
// file-indexer publishes. publishChange publishes via nc.Publish to
// seraph.file.<fileId>.changed, which JetStream captures on the stream AND
// delivers to core NATS subscribers on seraph.file.*.changed; the test reads
// them off the core NATS subscription.
func (e *consumerTestEnv) subscribeChanges(t *testing.T) chan events.FileChangedEvent {
	t.Helper()
	rawCh := make(chan *nats.Msg, 64)
	sub, err := e.nc.ChanSubscribe(events.FileChangedTopic, rawCh)
	require.NoError(t, err)
	t.Cleanup(func() { _ = sub.Unsubscribe() })

	evCh := make(chan events.FileChangedEvent, 64)
	go func() {
		for msg := range rawCh {
			ev := events.FileChangedEvent{}
			if err := ev.Unmarshal(msg.Data); err == nil {
				select {
				case evCh <- ev:
				case <-time.After(5 * time.Second):
					return
				}
			}
		}
	}()
	return evCh
}

func collectChanges(t *testing.T, ch chan events.FileChangedEvent, want int) []events.FileChangedEvent {
	t.Helper()
	var got []events.FileChangedEvent
	deadline := time.After(5 * time.Second)
	for len(got) < want {
		select {
		case ev := <-ch:
			got = append(got, ev)
		case <-deadline:
			require.Failf(t, "timed out waiting for FileChangedEvent", "wanted %d, got %d: %v", want, len(got), got)
			return got
		}
	}
	return got
}

func assertNoChanges(t *testing.T, ch chan events.FileChangedEvent, window time.Duration) {
	t.Helper()
	select {
	case ev := <-ch:
		require.Failf(t, "unexpected FileChangedEvent", "%v", ev)
	case <-time.After(window):
	}
}

func (e *consumerTestEnv) fileExists(t *testing.T, id primitive.ObjectID) bool {
	t.Helper()
	coll := e.db.Collection("files")
	err := coll.FindOne(context.Background(), bson.M{"_id": id}).Err()
	if err == nil {
		return true
	}
	require.ErrorIs(t, err, mongo.ErrNoDocuments)
	return false
}

// fixObjectID returns a deterministic, non-zero ObjectID derived from a small
// integer so test fixtures have stable, readable ids.
func fixObjectID(n byte) primitive.ObjectID {
	var id primitive.ObjectID
	id[0] = 0x60
	id[len(id)-1] = n
	return id
}

func TestFileRemovedSingleFileEmitsOneDeletedEvent(t *testing.T) {
	env := setupConsumer(t)

	fileID := fixObjectID(1)
	provider := "prov-single"
	env.seedFiles(t, []seedFileSpec{
		{id: fileID, providerId: provider, path: "/Photos/a.jpg", isDir: false, mime: "image/jpeg", size: 10, modTime: 100},
	})

	ch := env.subscribeChanges(t)
	env.publishRemoved(t, provider, "/Photos/a.jpg")

	evs := collectChanges(t, ch, 1)
	assert.Equal(t, events.FileChangedEventDeleted, evs[0].Change)
	assert.Equal(t, "/Photos/a.jpg", evs[0].Path)
	assert.Equal(t, provider, evs[0].ProviderID)
	assert.False(t, env.fileExists(t, fileID))
}

func TestFileRemovedDirectoryFansOutPerFile(t *testing.T) {
	env := setupConsumer(t)

	provider := "prov-dir"
	dirID := fixObjectID(1)
	env.seedFiles(t, []seedFileSpec{
		{id: dirID, providerId: provider, path: "/Photos", isDir: true},
		{id: fixObjectID(2), providerId: provider, path: "/Photos/a.jpg", parentDir: dirID, isDir: false, mime: "image/jpeg"},
		{id: fixObjectID(3), providerId: provider, path: "/Photos/b.jpg", parentDir: dirID, isDir: false, mime: "image/jpeg"},
		{id: fixObjectID(4), providerId: provider, path: "/Photos/sub/c.jpg", parentDir: dirID, isDir: false, mime: "image/jpeg"},
		// an unrelated file that must NOT be touched
		{id: fixObjectID(5), providerId: provider, path: "/Videos/d.mp4", isDir: false, mime: "video/mp4"},
	})

	ch := env.subscribeChanges(t)
	env.publishRemoved(t, provider, "/Photos")

	evs := collectChanges(t, ch, 4)

	paths := map[string]string{}
	for _, ev := range evs {
		assert.Equal(t, events.FileChangedEventDeleted, ev.Change)
		assert.Equal(t, provider, ev.ProviderID)
		paths[ev.Path] = ev.Change
	}
	assert.ElementsMatch(t,
		[]string{"/Photos", "/Photos/a.jpg", "/Photos/b.jpg", "/Photos/sub/c.jpg"},
		keys(paths),
	)
	assert.NotContains(t, paths, "/Videos/d.mp4")

	// all four removed files are gone; the unrelated video remains
	assert.False(t, env.fileExists(t, dirID))
	assert.False(t, env.fileExists(t, fixObjectID(2)))
	assert.False(t, env.fileExists(t, fixObjectID(3)))
	assert.False(t, env.fileExists(t, fixObjectID(4)))
	assert.True(t, env.fileExists(t, fixObjectID(5)))
}

func TestRenameRemovesOldPathOnly(t *testing.T) {
	env := setupConsumer(t)

	provider := "prov-rename"
	oldID := fixObjectID(1)
	newID := fixObjectID(2)
	env.seedFiles(t, []seedFileSpec{
		{id: oldID, providerId: provider, path: "/old.jpg", isDir: false, mime: "image/jpeg"},
		{id: newID, providerId: provider, path: "/new.jpg", isDir: false, mime: "image/jpeg"},
	})

	ch := env.subscribeChanges(t)
	// the file-provider publishes a removal signal for the old path on rename;
	// the new path is not signalled as a deletion (it appears via the normal
	// FileInfoEvent/readdir path).
	env.publishRemoved(t, provider, "/old.jpg")

	evs := collectChanges(t, ch, 1)
	assert.Equal(t, events.FileChangedEventDeleted, evs[0].Change)
	assert.Equal(t, "/old.jpg", evs[0].Path)
	assert.False(t, env.fileExists(t, oldID))
	assert.True(t, env.fileExists(t, newID))
}

func TestFileRemovedUnknownPathIsNoop(t *testing.T) {
	env := setupConsumer(t)

	provider := "prov-noop"
	stayID := fixObjectID(1)
	env.seedFiles(t, []seedFileSpec{
		{id: stayID, providerId: provider, path: "/Photos/keep.jpg", isDir: false, mime: "image/jpeg"},
	})

	ch := env.subscribeChanges(t)
	// a path the index does not hold must produce no event and delete nothing
	env.publishRemoved(t, provider, "/Photos/never-indexed.jpg")

	assertNoChanges(t, ch, 500*time.Millisecond)
	assert.True(t, env.fileExists(t, stayID))
}

func TestFileRemovedIdempotentWithReaddir(t *testing.T) {
	env := setupConsumer(t)

	provider := "prov-idem"
	dirID := fixObjectID(1)
	aID := fixObjectID(2)
	bID := fixObjectID(3)
	cID := fixObjectID(4)
	env.seedFiles(t, []seedFileSpec{
		{id: dirID, providerId: provider, path: "/Photos", isDir: true},
		{id: aID, providerId: provider, path: "/Photos/a.jpg", parentDir: dirID, isDir: false, mime: "image/jpeg"},
		{id: bID, providerId: provider, path: "/Photos/b.jpg", parentDir: dirID, isDir: false, mime: "image/jpeg"},
		{id: cID, providerId: provider, path: "/Photos/c.jpg", parentDir: dirID, isDir: false, mime: "image/jpeg"},
	})

	ch := env.subscribeChanges(t)

	// step 1: removal signal deletes b.jpg immediately
	env.publishRemoved(t, provider, "/Photos/b.jpg")
	evs := collectChanges(t, ch, 1)
	assert.Equal(t, events.FileChangedEventDeleted, evs[0].Change)
	assert.Equal(t, "/Photos/b.jpg", evs[0].Path)
	assert.False(t, env.fileExists(t, bID))
	assert.True(t, env.fileExists(t, aID))
	assert.True(t, env.fileExists(t, cID))

	// step 2: a later complete Readdir of /Photos, which now lists only a and
	// c (total 2), must NOT emit a second deletion event for b -- b is already
	// absent from the files collection, so handleReaddirComplete's $nin filter
	// cannot match it. Drive the complete path directly via the test export.
	env.seedReaddir(t, []fileindexer.Readdir{
		{Readdir: "session-1", Index: 0, Total: 2, File: aID, ParentDir: dirID},
		{Readdir: "session-1", Index: 1, Total: 2, File: cID, ParentDir: dirID},
	})

	dirFile := &fileindexer.File{Id: aID, Path: "/Photos/a.jpg", ProviderId: provider, IsDir: false, ParentDir: dirID}
	err := fileindexer.ConsumerHandleReaddirComplete(env.cons, context.Background(), dirFile, &events.ReadDir{Readdir: "session-1", Total: 2})
	require.NoError(t, err)

	// no further deletion event for the already-removed b, and a and c survive
	assertNoChanges(t, ch, 500*time.Millisecond)
	assert.True(t, env.fileExists(t, aID))
	assert.True(t, env.fileExists(t, cID))
	assert.False(t, env.fileExists(t, bID))
}

func keys(m map[string]string) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	return ks
}
