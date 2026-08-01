// Copyright © 2026 Benjamin Schmitz

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

package webdav

// Exercises the atomic-PUT decorator against the real stack it runs behind in
// production: a request-provider.LimitedFs, wrapping a fileprovider.Client,
// talking over a real NATS connection to a FileProviderServer backed by real
// files on disk - fronted by a real HTTP server so an aborted upload is an
// actual dropped TCP connection, not a canceled context.
//
// Unlike atomic_put_test.go, which drives atomicPutFs directly against
// webdav.Dir, this exercises the NATS wire protocol and its chunking
// (client.go's maxPayload), which is where a partially-flushed multi-chunk
// write could otherwise leak into the destination file.

import (
	"bytes"
	"context"
	"crypto/rand"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/hamba/avro/v2"
	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/tracing"
)

var integrationNatsServer *server.Server

func TestMain(m *testing.M) {
	opts := &server.Options{}
	var err error
	integrationNatsServer, err = server.NewServer(opts)
	if err != nil {
		panic(err)
	}
	integrationNatsServer.Start()
	if !integrationNatsServer.ReadyForConnections(10 * time.Second) {
		panic("embedded NATS server did not become ready")
	}

	code := m.Run()

	integrationNatsServer.Shutdown()
	os.Exit(code)
}

// integrationFixture wires a fileprovider client/server pair over the shared
// embedded NATS server, backed by a fresh temp directory, and fronts the
// resulting webdav.FileSystem - staged exactly as delegatingFs.providerFs does
// in production - with a real listening HTTP server.
type integrationFixture struct {
	t          *testing.T
	dir        string
	server     *fileprovider.FileProviderServer
	nc         *nats.Conn
	client     fileprovider.Client
	handler    *httptest.Server
	writeCount *writeCounter
}

// writeCounter counts FileWriteRequest messages actually reaching the file
// provider over NATS - the observable protocol consequence of how the PUT
// handler's destination is buffered upstream. It rides along as an extra
// subscriber on the per-file request subject: NATS request/reply is ordinary
// publish/subscribe underneath, so this receives its own copy of every
// request without disturbing the provider's own reply.
type writeCounter struct {
	msgApi avro.API
	count  atomic.Int64
}

func newWriteCounter(t *testing.T, nc *nats.Conn) *writeCounter {
	t.Helper()

	wc := &writeCounter{msgApi: fileprovider.NewMessageApi()}
	// "*" matches the single fileId token that follows the fixed prefix
	sub, err := nc.Subscribe(fileprovider.FileProviderFileTopicPrefix+"*", func(msg *nats.Msg) {
		req := fileprovider.FileProviderFileRequest{}
		if err := wc.msgApi.Unmarshal(fileprovider.FileProviderFileRequestSchema, msg.Data, &req); err != nil {
			return
		}
		if _, ok := req.Request.(fileprovider.FileWriteRequest); ok {
			wc.count.Add(1)
		}
	})
	require.NoError(t, err)
	t.Cleanup(func() { sub.Unsubscribe() })

	return wc
}

func (w *writeCounter) reset() {
	w.count.Store(0)
}

func (w *writeCounter) writes() int64 {
	return w.count.Load()
}

func newIntegrationFixture(t *testing.T) *integrationFixture {
	t.Helper()

	dir := t.TempDir()

	nc, err := nats.Connect(integrationNatsServer.ClientURL())
	require.NoError(t, err)

	logger := logging.New(logging.Params{})
	logger.SetLevel(slog.LevelDebug)

	providerId := "atomic-put-it-" + t.Name()
	fpServer, err := fileprovider.NewFileProviderServer(fileprovider.ServerParams{
		Logger:  logger,
		Tracing: tracing.NewNoopTracing(),
		Nc:      nc,
		Js:      nil,
	}, providerId, webdav.Dir(dir), false)
	require.NoError(t, err)
	require.NoError(t, fpServer.Start())

	client := fileprovider.NewFileProviderClient(providerId, nc, logger)
	writeCount := newWriteCounter(t, nc)

	staged := &atomicPutFs{
		FileSystem: client,
		log:        logger.GetLogger("webdav.fs"),
		sweeper:    newStagingSweeper(logger.GetLogger("webdav.fs")),
	}
	limited := &fileprovider.LimitedFs{FileSystem: staged, ReadOnly: false}

	handler := withAtomicPut(&webdav.Handler{
		FileSystem: limited,
		LockSystem: webdav.NewMemLS(),
	})
	httpServer := httptest.NewServer(handler)

	f := &integrationFixture{t: t, dir: dir, server: fpServer, nc: nc, client: client, handler: httpServer, writeCount: writeCount}
	t.Cleanup(f.close)
	return f
}

func (f *integrationFixture) close() {
	f.handler.Close()
	f.client.Close()
	require.NoError(f.t, f.server.Stop(true))
	f.nc.Close()
}

func (f *integrationFixture) diskContent(name string) ([]byte, error) {
	return os.ReadFile(filepath.Join(f.dir, name))
}

func (f *integrationFixture) diskStagingFiles() []string {
	f.t.Helper()
	entries, err := os.ReadDir(f.dir)
	require.NoError(f.t, err)
	names := make([]string, 0)
	for _, entry := range entries {
		if isStagingName(entry.Name()) {
			names = append(names, entry.Name())
		}
	}
	return names
}

func (f *integrationFixture) put(t *testing.T, name string, contentLength int64, body io.Reader) *http.Response {
	req, err := http.NewRequest(http.MethodPut, f.handler.URL+name, body)
	require.NoError(t, err)
	req.ContentLength = contentLength

	res, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	return res
}

// putThenDrop sends the request line, headers and prefix of the body over a
// raw TCP connection and then closes it without sending the rest, simulating
// a client that disappears mid-upload.
func (f *integrationFixture) putThenDrop(t *testing.T, name string, announcedLength int64, prefix []byte) {
	t.Helper()

	parsed, err := url.Parse(f.handler.URL)
	require.NoError(t, err)

	conn, err := net.Dial("tcp", parsed.Host)
	require.NoError(t, err)
	defer conn.Close()

	request := fmt.Sprintf("PUT %s HTTP/1.1\r\nHost: %s\r\nContent-Length: %d\r\n\r\n", name, parsed.Host, announcedLength)
	_, err = conn.Write([]byte(request))
	require.NoError(t, err)
	_, err = conn.Write(prefix)
	require.NoError(t, err)

	// give the server a moment to read what was sent before we cut the connection
	time.Sleep(50 * time.Millisecond)
}

func TestAtomicPutIntegration(t *testing.T) {
	t.Run("round-trips a large multi-chunk upload through NATS", func(t *testing.T) {
		f := newIntegrationFixture(t)

		// bigger than fileprovider's maxPayload (768KiB), so the client splits
		// this into several NATS round trips
		payload := make([]byte, 3*1024*1024)
		_, err := rand.Read(payload)
		require.NoError(t, err)

		f.writeCount.reset()
		res := f.put(t, "/big.bin", int64(len(payload)), bytes.NewReader(payload))
		require.Equal(t, http.StatusCreated, res.StatusCode)
		res.Body.Close()

		content, err := f.diskContent("big.bin")
		require.NoError(t, err)
		assert.True(t, bytes.Equal(content, payload), "stored content did not match what was uploaded")
		assert.Empty(t, f.diskStagingFiles())

		// the destination is buffered up to fileprovider.MaxPayload, so the
		// number of FileWriteRequest messages that actually reach the provider
		// tracks len(payload)/MaxPayload rather than the 32KB chunk size
		// net/http's io.Copy uses internally - an unbuffered destination would
		// have needed on the order of 3MiB/32KiB =~ 96 writes instead.
		wantMaxWrites := (int64(len(payload)) + fileprovider.MaxPayload - 1) / fileprovider.MaxPayload
		assert.LessOrEqual(t, f.writeCount.writes(), wantMaxWrites,
			"expected at most %d writes (size/MaxPayload) to reach the file provider, got %d", wantMaxWrites, f.writeCount.writes())
	})

	t.Run("replaces an existing file only once the upload is complete", func(t *testing.T) {
		f := newIntegrationFixture(t)

		ctx := context.Background()
		seed, err := f.client.OpenFile(ctx, "existing.txt", os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0666)
		require.NoError(t, err)
		_, err = seed.Write([]byte("old content"))
		require.NoError(t, err)
		require.NoError(t, seed.Close())

		res := f.put(t, "/existing.txt", 3, bytes.NewReader([]byte("new")))
		require.Equal(t, http.StatusCreated, res.StatusCode)
		res.Body.Close()

		content, err := f.diskContent("existing.txt")
		require.NoError(t, err)
		assert.Equal(t, "new", string(content))
		assert.Empty(t, f.diskStagingFiles())
	})

	t.Run("preserves the previous file when the connection drops mid-upload", func(t *testing.T) {
		f := newIntegrationFixture(t)

		ctx := context.Background()
		seed, err := f.client.OpenFile(ctx, "existing.txt", os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0666)
		require.NoError(t, err)
		_, err = seed.Write([]byte("old content"))
		require.NoError(t, err)
		require.NoError(t, seed.Close())

		// announce far more than we send, and disappear
		f.putThenDrop(t, "/existing.txt", 10*1024*1024, []byte("partial upload"))

		// the fileprovider server only notices the dropped connection once the
		// handler's Close() runs; give it a moment before asserting
		require.Eventually(t, func() bool {
			return len(f.diskStagingFiles()) == 0
		}, 5*time.Second, 20*time.Millisecond, "staging file was not cleaned up")

		content, err := f.diskContent("existing.txt")
		require.NoError(t, err)
		assert.Equal(t, "old content", string(content), "previous content must survive an interrupted upload")
	})

	t.Run("leaves nothing behind when a large upload of a new file is interrupted mid-chunk", func(t *testing.T) {
		f := newIntegrationFixture(t)

		// exceed maxPayload so at least one full NATS chunk is flushed to the
		// staging file through the real wire protocol before we cut the
		// connection - this is the scenario a naive Close()-only rollback could
		// still get wrong
		prefix := make([]byte, 1024*1024)
		_, err := rand.Read(prefix)
		require.NoError(t, err)

		f.putThenDrop(t, "/new.bin", 10*1024*1024, prefix)

		require.Eventually(t, func() bool {
			return len(f.diskStagingFiles()) == 0
		}, 5*time.Second, 20*time.Millisecond, "staging file was not cleaned up")

		_, err = f.diskContent("new.bin")
		assert.ErrorIs(t, err, os.ErrNotExist, "no file should exist at the destination")
	})
}
