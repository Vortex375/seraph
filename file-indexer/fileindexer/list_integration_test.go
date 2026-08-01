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

	// Siblings sharing "/Photos" as a string prefix but NOT beneath the
	// "/Photos" directory. These must never be returned, whether they sort
	// ABOVE the "/" boundary ('2' = 0x32 > '/' = 0x2F) or BELOW it -- every
	// byte under '0' (0x30) qualifies for the latter, so the bottom of the
	// range has to be closed just as carefully as the top.
	aboveBoundary := []string{"/Photos2", "/Photos2/c.jpg"}
	belowBoundary := []string{"/Photos.txt", "/Photos-old", "/Photos-old/e.jpg", "/Photos backup", "/Photos+1", "/Photos,list"}

	seeds := []seedFile{
		{providerId: "prov1", path: "/Photos", isDir: true},
		{providerId: "prov1", path: "/Photos/a.jpg", isDir: false, mime: "image/jpeg"},
		{providerId: "prov1", path: "/Photos/sub/b.jpg", isDir: false, mime: "image/jpeg"},
		// unrelated sibling directory
		{providerId: "prov1", path: "/Videos/d.mp4", isDir: false, mime: "video/mp4"},
	}
	for _, p := range append(append([]string{}, aboveBoundary...), belowBoundary...) {
		seeds = append(seeds, seedFile{providerId: "prov1", path: p, mime: "text/plain"})
	}
	env.seed(t, seeds)

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
	for _, p := range aboveBoundary {
		assert.NotContains(t, paths, p, "sibling sorting above the / boundary must not match the prefix")
	}
	for _, p := range belowBoundary {
		assert.NotContains(t, paths, p, "sibling sorting below the / boundary must not match the prefix")
	}
	assert.NotContains(t, paths, "/Videos/d.mp4")
}

// TestListPrefixDirectoryBoundaryWhilePaging pins the boundary against the
// paged path too: the cursor rewrites the range bounds, so an off-by-one
// there could readmit a sibling on a later page.
func TestListPrefixDirectoryBoundaryWhilePaging(t *testing.T) {
	env := setupList(t)

	env.seed(t, []seedFile{
		{providerId: "prov1", path: "/Photos", isDir: true},
		{providerId: "prov1", path: "/Photos/a.jpg", mime: "image/jpeg"},
		{providerId: "prov1", path: "/Photos/b.jpg", mime: "image/jpeg"},
		{providerId: "prov1", path: "/Photos/c.jpg", mime: "image/jpeg"},
		{providerId: "prov1", path: "/Photos.txt", mime: "text/plain"},
		{providerId: "prov1", path: "/Photos-old", isDir: true},
		{providerId: "prov1", path: "/Photos2/c.jpg", mime: "image/jpeg"},
	})

	var paths []string
	cursor := ""
	for {
		reply := doList(t, env.nc, events.FileIndexListRequest{
			ProviderId: "prov1",
			Path:       "/Photos",
			PageSize:   1,
			Cursor:     cursor,
		})
		require.Equal(t, "", reply.Error)
		for _, e := range reply.Entries {
			paths = append(paths, e.Path)
		}
		if !reply.HasMore {
			break
		}
		cursor = reply.NextCursor
		require.Less(t, len(paths), 10, "paging is not terminating")
	}

	assert.Equal(t, []string{"/Photos", "/Photos/a.jpg", "/Photos/b.jpg", "/Photos/c.jpg"}, paths)
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

	files := []seedFile{{providerId: "prov1", path: "/Photos", isDir: true}}
	for i := 0; i < 50; i++ {
		files = append(files, seedFile{
			providerId: "prov1",
			path:       fmt.Sprintf("/Photos/img%03d.jpg", i),
			isDir:      false,
			mime:       "image/jpeg",
		})
	}
	for i := 0; i < 50; i++ {
		// Noise sharing "/Photos" as a string prefix but outside the
		// range, on both sides of the "/" boundary. A plan that threw its
		// index bounds away would examine these too.
		files = append(files,
			seedFile{providerId: "prov1", path: fmt.Sprintf("/Photos2/img%03d.jpg", i), mime: "image/jpeg"},
			seedFile{providerId: "prov1", path: fmt.Sprintf("/Photos-old/img%03d.jpg", i), mime: "image/jpeg"},
		)
	}
	env.seed(t, files)

	// Explain the exact filters/sort the production query path builds: the
	// point lookup for the prefix itself, the descendant range scan, and
	// the cursor-narrowed continuation of that range. Every data-access
	// leaf of every plan must be a bounded index scan.
	selfFilter, ok := fileindexer.BuildPrefixSelfFilter("prov1", "/Photos")
	require.True(t, ok)

	descendants, ok := fileindexer.BuildDescendantsFilter("prov1", "/Photos", "")
	require.True(t, ok)

	continuation, ok := fileindexer.BuildDescendantsFilter("prov1", "/Photos", "/Photos/img010.jpg")
	require.True(t, ok)

	// none of the production filters may use $or: MongoDB answers such an
	// $or by scanning the provider's whole key space with the $or as a
	// residual filter, which silently throws the index bounds away
	for _, f := range []bson.M{selfFilter, descendants, continuation} {
		require.NotContains(t, f, "$or", "filters must stay single bounded index ranges")
	}

	for name, filter := range map[string]bson.M{
		"prefix point lookup": selfFilter,
		"descendant range":    descendants,
		"continuation page":   continuation,
	} {
		t.Run(name, func(t *testing.T) {
			var explainResult bson.M
			cmd := bson.D{
				{Key: "explain", Value: bson.D{
					{Key: "find", Value: "files"},
					{Key: "filter", Value: filter},
					{Key: "sort", Value: fileindexer.ListSort},
				}},
				{Key: "verbosity", Value: "executionStats"},
			}
			require.NoError(t, env.db.RunCommand(context.Background(), cmd).Decode(&explainResult))

			winningPlan := extractWinningPlan(t, explainResult)
			stages := findLeafStages(winningPlan)

			require.NotEmpty(t, stages, "no data-access stage found in plan: %v", winningPlan)
			for _, s := range stages {
				assert.Equal(t, "IXSCAN", s, "expected every data-access stage to be an index scan, got %s; full plan: %v", s, winningPlan)
				assert.NotEqual(t, "COLLSCAN", s, "query degraded to a collection scan; full plan: %v", winningPlan)
			}

			for _, n := range findIndexNames(winningPlan) {
				assert.Equal(t, "files_providerId_path_idx", n)
			}

			// the scan must actually be bounded: it may not touch the
			// /Photos2 noise documents
			execStats, ok := explainResult["executionStats"].(bson.M)
			require.True(t, ok, "missing executionStats: %v", explainResult)
			examined := toInt(execStats["totalKeysExamined"])
			assert.Less(t, examined, 60, "expected a bounded range scan, but %d index keys were examined", examined)
		})
	}
}

func toInt(v any) int {
	switch n := v.(type) {
	case int32:
		return int(n)
	case int64:
		return int(n)
	case float64:
		return int(n)
	}
	return -1
}

func extractWinningPlan(t *testing.T, explainResult bson.M) bson.M {
	t.Helper()
	queryPlanner, ok := explainResult["queryPlanner"].(bson.M)
	require.True(t, ok, "explain result missing queryPlanner: %v", explainResult)
	winningPlan, ok := queryPlanner["winningPlan"].(bson.M)
	require.True(t, ok, "explain result missing winningPlan: %v", queryPlanner)
	return winningPlan
}

// findLeafStages walks the whole plan tree -- through wrapper stages like
// SORT and FETCH and through branching stages like OR/SORT_MERGE, which
// carry several children under "inputStages" -- and returns the stage name
// of every data-access leaf. An $or plan has one leaf per branch, so this
// catches a single branch silently degrading to a collection scan.
func findLeafStages(plan bson.M) []string {
	stage, _ := plan["stage"].(string)
	if stage == "IXSCAN" || stage == "COLLSCAN" {
		return []string{stage}
	}

	var stages []string
	if inputStage, ok := plan["inputStage"].(bson.M); ok {
		stages = append(stages, findLeafStages(inputStage)...)
	}
	if inputStages, ok := plan["inputStages"].(bson.A); ok {
		for _, s := range inputStages {
			if sub, ok := s.(bson.M); ok {
				stages = append(stages, findLeafStages(sub)...)
			}
		}
	}
	return stages
}

func findIndexNames(plan bson.M) []string {
	var names []string
	if name, ok := plan["indexName"].(string); ok {
		names = append(names, name)
	}
	if inputStage, ok := plan["inputStage"].(bson.M); ok {
		names = append(names, findIndexNames(inputStage)...)
	}
	if inputStages, ok := plan["inputStages"].(bson.A); ok {
		for _, s := range inputStages {
			if sub, ok := s.(bson.M); ok {
				names = append(names, findIndexNames(sub)...)
			}
		}
	}
	return names
}
