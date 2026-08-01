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
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/spf13/viper"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/testcontainers/testcontainers-go"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.uber.org/fx/fxtest"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/file-indexer/fileindexer"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/mongodb"
	"umbasa.net/seraph/tracing"
)

var natsServer *server.Server
var mongoContainer testcontainers.Container
var mongoUrl string
var v *viper.Viper

func TestMain(m *testing.M) {
	setup()
	code := m.Run()
	shutdown()
	os.Exit(code)
}

func setup() {
	opts := &server.Options{
		JetStream: true,
		StoreDir:  os.TempDir(),
	}
	var err error
	natsServer, err = server.NewServer(opts)
	if err != nil {
		panic(err)
	}

	natsServer.Start()
	if !natsServer.ReadyForConnections(10 * time.Second) {
		panic("embedded NATS server did not become ready")
	}

	req := testcontainers.ContainerRequest{
		Image:        "mongo:8",
		ExposedPorts: []string{"27017/tcp"},
	}

	mongoContainer, err = testcontainers.GenericContainer(context.Background(), testcontainers.GenericContainerRequest{
		ContainerRequest: req,
		Started:          true,
	})
	if err != nil {
		panic(err)
	}

	endpoint, err := mongoContainer.Endpoint(context.Background(), "")
	if err != nil {
		panic(err)
	}

	mongoUrl = fmt.Sprintf("mongodb://%s/", endpoint)

	v = viper.New()
	v.Set("mongo.url", mongoUrl)
	v.Set("mongo.db", "file_indexer_test")
}

func shutdown() {
	if natsServer != nil {
		natsServer.Shutdown()
		natsServer = nil
	}
	if mongoContainer != nil {
		testcontainers.TerminateContainer(mongoContainer)
	}
}

// testEnv wires up a fresh database (so tests don't see each other's data)
// plus a running fileindexer.List NATS handler backed by it.
type testEnv struct {
	nc     *nats.Conn
	db     *mongo.Database
	dbName string
}

func setupList(t *testing.T) *testEnv {
	t.Helper()

	nc, err := nats.Connect(natsServer.ClientURL())
	require.NoError(t, err)
	t.Cleanup(nc.Close)

	dbName := fmt.Sprintf("file_indexer_test_%s", uniqueSuffix())

	localV := viper.New()
	localV.Set("mongo.url", mongoUrl)
	localV.Set("mongo.db", dbName)

	migrations, err := fileindexer.NewMigrations(localV)
	require.NoError(t, err)
	_ = migrations

	res, err := mongodb.NewClient(mongodb.ClientParams{
		Viper:   localV,
		Tracing: tracing.NewNoopTracing(),
		Lc:      fxtest.NewLifecycle(t),
	})
	require.NoError(t, err)

	db := res.Client.Database(dbName)

	logger := logging.New(logging.Params{})
	logger.SetLevel(slog.LevelDebug)

	lc := fxtest.NewLifecycle(t)

	_, err = fileindexer.NewList(fileindexer.ListParams{
		Nc:      nc,
		Db:      db,
		Logger:  logger,
		Tracing: tracing.NewNoopTracing(),
		Mig:     migrations,
		Lc:      lc,
	})
	require.NoError(t, err)

	require.NoError(t, lc.Start(context.Background()))
	t.Cleanup(func() {
		_ = lc.Stop(context.Background())
	})

	return &testEnv{nc: nc, db: db, dbName: dbName}
}

var suffixCounter int

func uniqueSuffix() string {
	suffixCounter++
	return fmt.Sprintf("%d_%d", time.Now().UnixNano(), suffixCounter)
}

type seedFile struct {
	providerId string
	path       string
	size       int64
	modTime    int64
	isDir      bool
	mime       string
}

func (e *testEnv) seed(t *testing.T, files []seedFile) {
	t.Helper()
	coll := e.db.Collection("files")
	docs := make([]any, 0, len(files))
	for _, f := range files {
		docs = append(docs, bson.M{
			"providerId": f.providerId,
			"path":       f.path,
			"size":       f.size,
			"modTime":    f.modTime,
			"isDir":      f.isDir,
			"mime":       f.mime,
			"mode":       int64(0),
			"pending":    false,
		})
	}
	_, err := coll.InsertMany(context.Background(), docs)
	require.NoError(t, err)
}

// doList performs one NATS ack+reply round trip against the list handler.
func doList(t *testing.T, nc *nats.Conn, req events.FileIndexListRequest) events.FileIndexListReply {
	t.Helper()

	if req.RequestId == "" {
		req.RequestId = uniqueSuffix()
	}

	ackChan := make(chan *nats.Msg, 1)
	replyChan := make(chan *nats.Msg, 1)

	ackSub, err := nc.ChanSubscribe(fmt.Sprintf(events.FileIndexListAckTopicPattern, req.RequestId), ackChan)
	require.NoError(t, err)
	defer ackSub.Unsubscribe()

	replySub, err := nc.ChanSubscribe(fmt.Sprintf(events.FileIndexListReplyTopicPattern, req.RequestId), replyChan)
	require.NoError(t, err)
	defer replySub.Unsubscribe()

	data, err := json.Marshal(req)
	require.NoError(t, err)
	require.NoError(t, nc.Publish(events.FileIndexListRequestTopic, data))

	select {
	case msg := <-ackChan:
		ack := events.FileIndexListAck{}
		require.NoError(t, json.Unmarshal(msg.Data, &ack))
		assert.True(t, ack.Ack)
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for ack")
	}

	select {
	case msg := <-replyChan:
		reply := events.FileIndexListReply{}
		require.NoError(t, json.Unmarshal(msg.Data, &reply))
		assert.True(t, reply.Last)
		return reply
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for reply")
	}
	return events.FileIndexListReply{}
}

func TestListPrefixPaging(t *testing.T) {
	env := setupList(t)

	var files []seedFile
	for i := 0; i < 25; i++ {
		files = append(files, seedFile{
			providerId: "prov1",
			path:       fmt.Sprintf("/Photos/img%03d.jpg", i),
			size:       int64(i),
			modTime:    1000 + int64(i),
			isDir:      false,
			mime:       "image/jpeg",
		})
	}
	env.seed(t, files)

	seen := map[string]bool{}
	cursor := ""
	pages := 0
	for {
		reply := doList(t, env.nc, events.FileIndexListRequest{
			ProviderId: "prov1",
			Path:       "/Photos",
			PageSize:   10,
			Cursor:     cursor,
		})
		require.Equal(t, "", reply.Error)
		pages++

		for _, e := range reply.Entries {
			assert.False(t, seen[e.Path], "entry %s seen more than once", e.Path)
			seen[e.Path] = true
		}

		if !reply.HasMore {
			assert.Equal(t, "", reply.NextCursor)
			break
		}
		require.NotEmpty(t, reply.NextCursor)
		cursor = reply.NextCursor

		require.Less(t, pages, 10, "too many pages, paging is probably not terminating")
	}

	assert.Equal(t, 25, len(seen))
	assert.Equal(t, 3, pages) // 10 + 10 + 5
	for _, f := range files {
		assert.True(t, seen[f.path], "missing entry %s", f.path)
	}
}

func TestListPrefixOrderingStableAcrossPages(t *testing.T) {
	env := setupList(t)

	var files []seedFile
	names := []string{"c.txt", "a.txt", "e.txt", "b.txt", "d.txt"}
	for i, n := range names {
		files = append(files, seedFile{
			providerId: "prov1",
			path:       "/Docs/" + n,
			size:       int64(i),
			isDir:      false,
			mime:       "text/plain",
		})
	}
	env.seed(t, files)

	var allPaths []string
	cursor := ""
	for {
		reply := doList(t, env.nc, events.FileIndexListRequest{
			ProviderId: "prov1",
			Path:       "/Docs",
			PageSize:   2,
			Cursor:     cursor,
		})
		require.Equal(t, "", reply.Error)
		for _, e := range reply.Entries {
			allPaths = append(allPaths, e.Path)
		}
		if !reply.HasMore {
			break
		}
		cursor = reply.NextCursor
	}

	require.Equal(t, 5, len(allPaths))
	assert.True(t, isSorted(allPaths), "expected entries to be returned in stable sorted order, got %v", allPaths)
	assert.Equal(t, []string{"/Docs/a.txt", "/Docs/b.txt", "/Docs/c.txt", "/Docs/d.txt", "/Docs/e.txt"}, allPaths)
}

func isSorted(s []string) bool {
	for i := 1; i < len(s); i++ {
		if s[i-1] > s[i] {
			return false
		}
	}
	return true
}

func TestListPrefixDirectoryBoundary(t *testing.T) {
	env := setupList(t)

	env.seed(t, []seedFile{
		{providerId: "prov1", path: "/Photos", isDir: true},
		{providerId: "prov1", path: "/Photos/a.jpg", isDir: false, mime: "image/jpeg"},
		{providerId: "prov1", path: "/Photos/sub/b.jpg", isDir: false, mime: "image/jpeg"},
		// sibling that shares the "/Photos" prefix as a string but is NOT
		// beneath the "/Photos" directory -- must never be returned.
		{providerId: "prov1", path: "/Photos2", isDir: true},
		{providerId: "prov1", path: "/Photos2/c.jpg", isDir: false, mime: "image/jpeg"},
		// unrelated sibling directory
		{providerId: "prov1", path: "/Videos/d.mp4", isDir: false, mime: "video/mp4"},
	})

	reply := doList(t, env.nc, events.FileIndexListRequest{
		ProviderId: "prov1",
		Path:       "/Photos",
		PageSize:   100,
	})

	require.Equal(t, "", reply.Error)
	assert.False(t, reply.HasMore)

	var paths []string
	for _, e := range reply.Entries {
		paths = append(paths, e.Path)
	}

	assert.ElementsMatch(t, []string{"/Photos", "/Photos/a.jpg", "/Photos/sub/b.jpg"}, paths)
	assert.NotContains(t, paths, "/Photos2")
	assert.NotContains(t, paths, "/Photos2/c.jpg")
	assert.NotContains(t, paths, "/Videos/d.mp4")
}

func TestListPrefixEmptyOrUnknownReturnsEmptyPage(t *testing.T) {
	env := setupList(t)

	env.seed(t, []seedFile{
		{providerId: "prov1", path: "/Photos/a.jpg", isDir: false, mime: "image/jpeg"},
	})

	// unknown prefix
	reply := doList(t, env.nc, events.FileIndexListRequest{
		ProviderId: "prov1",
		Path:       "/DoesNotExist",
		PageSize:   10,
	})
	require.Equal(t, "", reply.Error)
	assert.Empty(t, reply.Entries)
	assert.False(t, reply.HasMore)

	// empty path
	reply = doList(t, env.nc, events.FileIndexListRequest{
		ProviderId: "prov1",
		Path:       "",
		PageSize:   10,
	})
	require.Equal(t, "", reply.Error)
	assert.Empty(t, reply.Entries)
	assert.False(t, reply.HasMore)

	// unknown provider
	reply = doList(t, env.nc, events.FileIndexListRequest{
		ProviderId: "does-not-exist",
		Path:       "/Photos",
		PageSize:   10,
	})
	require.Equal(t, "", reply.Error)
	assert.Empty(t, reply.Entries)
	assert.False(t, reply.HasMore)
}

func TestListPrefixEntryFields(t *testing.T) {
	env := setupList(t)

	env.seed(t, []seedFile{
		{providerId: "prov1", path: "/Photos", isDir: true},
		{providerId: "prov1", path: "/Photos/a.jpg", size: 1234, modTime: 5678, isDir: false, mime: "image/jpeg"},
	})

	reply := doList(t, env.nc, events.FileIndexListRequest{
		ProviderId: "prov1",
		Path:       "/Photos",
		PageSize:   10,
	})

	require.Equal(t, "", reply.Error)
	require.Equal(t, 2, len(reply.Entries))

	byPath := map[string]events.FileIndexListEntry{}
	for _, e := range reply.Entries {
		byPath[e.Path] = e
	}

	dir := byPath["/Photos"]
	assert.True(t, dir.IsDir)

	file := byPath["/Photos/a.jpg"]
	assert.False(t, file.IsDir)
	assert.Equal(t, int64(1234), file.Size)
	assert.Equal(t, int64(5678), file.ModTime)
	assert.Equal(t, "image/jpeg", file.Mime)
}

// TestListPrefixUsesIndexRangeScan proves via explain() that the query
// plan for a prefix listing is a bounded range scan (IXSCAN) over the
// existing unique compound index on (providerId, path) -- not a
// collection scan (COLLSCAN).
func TestListPrefixUsesIndexRangeScan(t *testing.T) {
	env := setupList(t)

	var files []seedFile
	for i := 0; i < 50; i++ {
		files = append(files, seedFile{
			providerId: "prov1",
			path:       fmt.Sprintf("/Photos/img%03d.jpg", i),
			isDir:      false,
			mime:       "image/jpeg",
		})
	}
	for i := 0; i < 50; i++ {
		// noise that shares a prefix as a string but must be excluded
		// from the range and would otherwise tempt a collection scan
		files = append(files, seedFile{
			providerId: "prov1",
			path:       fmt.Sprintf("/Photos2/img%03d.jpg", i),
			isDir:      false,
			mime:       "image/jpeg",
		})
	}
	env.seed(t, files)

	coll := env.db.Collection("files")

	filter := bson.M{
		"providerId": "prov1",
		"path":       bson.M{"$gte": "/Photos", "$lt": "/Photos0"},
	}

	var explainResult bson.M
	cmd := bson.D{
		{Key: "explain", Value: bson.D{
			{Key: "find", Value: "files"},
			{Key: "filter", Value: filter},
			{Key: "sort", Value: bson.D{{Key: "providerId", Value: 1}, {Key: "path", Value: 1}}},
		}},
		{Key: "verbosity", Value: "executionStats"},
	}
	require.NoError(t, coll.Database().RunCommand(context.Background(), cmd).Decode(&explainResult))

	winningPlan := extractWinningPlan(t, explainResult)
	stage := findStageType(winningPlan)

	assert.Equal(t, "IXSCAN", stage, "expected the winning plan to be an index range scan (IXSCAN), got %s; full plan: %v", stage, winningPlan)
	assert.NotEqual(t, "COLLSCAN", stage)

	indexName, _ := findIndexName(winningPlan)
	assert.Equal(t, "files_providerId_path_idx", indexName)
}

func extractWinningPlan(t *testing.T, explainResult bson.M) bson.M {
	t.Helper()
	queryPlanner, ok := explainResult["queryPlanner"].(bson.M)
	require.True(t, ok, "explain result missing queryPlanner: %v", explainResult)
	winningPlan, ok := queryPlanner["winningPlan"].(bson.M)
	require.True(t, ok, "explain result missing winningPlan: %v", queryPlanner)
	return winningPlan
}

// findStageType walks down the plan tree (through stages like SORT that
// wrap the actual data-access stage) and returns the stage name of the
// leaf/data-access node.
func findStageType(plan bson.M) string {
	stage, _ := plan["stage"].(string)
	if stage == "IXSCAN" || stage == "COLLSCAN" {
		return stage
	}
	if inputStage, ok := plan["inputStage"].(bson.M); ok {
		return findStageType(inputStage)
	}
	return stage
}

func findIndexName(plan bson.M) (string, bool) {
	if name, ok := plan["indexName"].(string); ok {
		return name, true
	}
	if inputStage, ok := plan["inputStage"].(bson.M); ok {
		return findIndexName(inputStage)
	}
	return "", false
}
