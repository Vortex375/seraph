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

import (
	"context"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"golang.org/x/net/webdav"
)

func testLogger() *slog.Logger {
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func newTestFs(dir string) *atomicPutFs {
	return &atomicPutFs{
		FileSystem: webdav.Dir(dir),
		log:        testLogger(),
		sweeper:    newStagingSweeper(testLogger()),
	}
}

func newTestHandler(dir string) http.Handler {
	return withAtomicPut(&webdav.Handler{
		FileSystem: newTestFs(dir),
		LockSystem: webdav.NewMemLS(),
	})
}

// put performs a PUT of body, announcing contentLength bytes regardless of what
// body actually delivers.
func put(handler http.Handler, path string, contentLength int64, body io.Reader) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPut, path, body)
	req.ContentLength = contentLength
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	return rec
}

// truncatedReader delivers prefix and then fails, like a connection that drops
// halfway through an upload.
type truncatedReader struct {
	prefix []byte
	onRead func()
}

func (r *truncatedReader) Read(p []byte) (int, error) {
	if r.onRead != nil {
		r.onRead()
		r.onRead = nil
	}
	if len(r.prefix) == 0 {
		return 0, io.ErrUnexpectedEOF
	}
	n := copy(p, r.prefix)
	r.prefix = r.prefix[n:]
	return n, nil
}

func stagingFiles(t *testing.T, dir string) []string {
	t.Helper()

	entries, err := os.ReadDir(dir)
	require.NoError(t, err)

	names := make([]string, 0)
	for _, entry := range entries {
		if isStagingName(entry.Name()) {
			names = append(names, entry.Name())
		}
	}
	return names
}

func TestAtomicPut(t *testing.T) {
	t.Run("creates a new file", func(t *testing.T) {
		dir := t.TempDir()
		handler := newTestHandler(dir)

		res := put(handler, "/new.txt", 5, strings.NewReader("hello"))

		assert.Equal(t, http.StatusCreated, res.Code)
		assert.NotEmpty(t, res.Header().Get("ETag"))
		content, err := os.ReadFile(filepath.Join(dir, "new.txt"))
		require.NoError(t, err)
		assert.Equal(t, "hello", string(content))
		assert.Empty(t, stagingFiles(t, dir))
	})

	t.Run("replaces an existing file", func(t *testing.T) {
		dir := t.TempDir()
		target := filepath.Join(dir, "existing.txt")
		require.NoError(t, os.WriteFile(target, []byte("old content"), 0666))
		handler := newTestHandler(dir)

		res := put(handler, "/existing.txt", 3, strings.NewReader("new"))

		assert.Equal(t, http.StatusCreated, res.Code)
		content, err := os.ReadFile(target)
		require.NoError(t, err)
		assert.Equal(t, "new", string(content))
		assert.Empty(t, stagingFiles(t, dir))
	})

	t.Run("keeps the previous content when the upload is interrupted", func(t *testing.T) {
		dir := t.TempDir()
		target := filepath.Join(dir, "existing.txt")
		require.NoError(t, os.WriteFile(target, []byte("old content"), 0666))
		handler := newTestHandler(dir)

		// the destination must be untouched while the body is still arriving
		var duringUpload string
		body := &truncatedReader{
			prefix: []byte("partial"),
			onRead: func() {
				content, err := os.ReadFile(target)
				require.NoError(t, err)
				duringUpload = string(content)
			},
		}

		res := put(handler, "/existing.txt", 1024, body)

		assert.Equal(t, http.StatusMethodNotAllowed, res.Code)
		assert.Equal(t, "old content", duringUpload)
		content, err := os.ReadFile(target)
		require.NoError(t, err)
		assert.Equal(t, "old content", string(content))
		assert.Empty(t, stagingFiles(t, dir))
	})

	t.Run("leaves no file behind when the upload of a new file is interrupted", func(t *testing.T) {
		dir := t.TempDir()
		handler := newTestHandler(dir)

		res := put(handler, "/new.txt", 1024, &truncatedReader{prefix: []byte("partial")})

		assert.Equal(t, http.StatusMethodNotAllowed, res.Code)
		_, err := os.Stat(filepath.Join(dir, "new.txt"))
		assert.ErrorIs(t, err, os.ErrNotExist)
		assert.Empty(t, stagingFiles(t, dir))
	})

	t.Run("rejects a body shorter than the announced content length", func(t *testing.T) {
		dir := t.TempDir()
		target := filepath.Join(dir, "existing.txt")
		require.NoError(t, os.WriteFile(target, []byte("old content"), 0666))
		handler := newTestHandler(dir)

		// the body ends cleanly, it is just shorter than promised
		res := put(handler, "/existing.txt", 1024, strings.NewReader("short"))

		assert.Equal(t, http.StatusMethodNotAllowed, res.Code)
		content, err := os.ReadFile(target)
		require.NoError(t, err)
		assert.Equal(t, "old content", string(content))
		assert.Empty(t, stagingFiles(t, dir))
	})

	t.Run("accepts a body of unknown length", func(t *testing.T) {
		dir := t.TempDir()
		handler := newTestHandler(dir)

		res := put(handler, "/chunked.txt", -1, strings.NewReader("hello"))

		assert.Equal(t, http.StatusCreated, res.Code)
		content, err := os.ReadFile(filepath.Join(dir, "chunked.txt"))
		require.NoError(t, err)
		assert.Equal(t, "hello", string(content))
	})

	t.Run("fails when the destination directory does not exist", func(t *testing.T) {
		dir := t.TempDir()
		handler := newTestHandler(dir)

		res := put(handler, "/missing/new.txt", 5, strings.NewReader("hello"))

		assert.Equal(t, http.StatusConflict, res.Code)
		assert.Empty(t, stagingFiles(t, dir))
	})

	t.Run("does not stage requests other than PUT", func(t *testing.T) {
		dir := t.TempDir()
		require.NoError(t, os.WriteFile(filepath.Join(dir, "existing.txt"), []byte("content"), 0666))
		handler := newTestHandler(dir)

		req := httptest.NewRequest(http.MethodGet, "/existing.txt", nil)
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)

		assert.Equal(t, http.StatusOK, rec.Code)
		assert.Equal(t, "content", rec.Body.String())
	})
}

// TestPutOverRealConnection checks the assumption the staging logic rests on:
// that net/http surfaces a client that vanishes mid-upload as a read error on
// the request body rather than as a clean end of body.
func TestPutOverRealConnection(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "existing.txt")
	require.NoError(t, os.WriteFile(target, []byte("old content"), 0666))

	done := make(chan struct{})
	handler := newTestHandler(dir)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer close(done)
		handler.ServeHTTP(w, r)
	}))
	defer server.Close()

	conn, err := net.Dial("tcp", server.Listener.Addr().String())
	require.NoError(t, err)

	_, err = io.WriteString(conn, "PUT /existing.txt HTTP/1.1\r\n"+
		"Host: "+server.Listener.Addr().String()+"\r\n"+
		"Content-Length: 1024\r\n"+
		"\r\n"+
		"partial")
	require.NoError(t, err)
	// drop the connection instead of sending the remaining bytes
	require.NoError(t, conn.Close())

	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("server did not finish handling the aborted upload")
	}

	content, err := os.ReadFile(target)
	require.NoError(t, err)
	assert.Equal(t, "old content", string(content))
	assert.Empty(t, stagingFiles(t, dir))
}

func TestStagingFilesAreHiddenFromListings(t *testing.T) {
	dir := t.TempDir()
	require.NoError(t, os.WriteFile(filepath.Join(dir, "visible.txt"), []byte("x"), 0666))
	require.NoError(t, os.WriteFile(filepath.Join(dir, stagingName()), []byte("x"), 0666))

	file, err := newTestFs(dir).OpenFile(context.Background(), "/", os.O_RDONLY, 0)
	require.NoError(t, err)
	defer file.Close()

	infos, err := file.Readdir(-1)
	require.NoError(t, err)
	require.Len(t, infos, 1)
	assert.Equal(t, "visible.txt", infos[0].Name())
}

func TestSweepRemovesOrphanedStagingFiles(t *testing.T) {
	dir := t.TempDir()
	fsys := newTestFs(dir)

	orphan := stagingName()
	recent := stagingName()
	require.NoError(t, os.WriteFile(filepath.Join(dir, orphan), []byte("x"), 0666))
	require.NoError(t, os.WriteFile(filepath.Join(dir, recent), []byte("x"), 0666))
	require.NoError(t, os.WriteFile(filepath.Join(dir, "keep.txt"), []byte("x"), 0666))

	stale := time.Now().Add(-2 * stagingMaxAge)
	require.NoError(t, os.Chtimes(filepath.Join(dir, orphan), stale, stale))
	require.NoError(t, os.Chtimes(filepath.Join(dir, "keep.txt"), stale, stale))

	fsys.sweeper.sweep(context.Background(), fsys.FileSystem, "/")

	_, err := os.Stat(filepath.Join(dir, orphan))
	assert.ErrorIs(t, err, os.ErrNotExist, "stale staging file should be swept")
	assert.FileExists(t, filepath.Join(dir, recent), "recent staging file may still be an upload in flight")
	assert.FileExists(t, filepath.Join(dir, "keep.txt"), "regular files are never swept")
}

func TestSweepIsRateLimitedPerDirectory(t *testing.T) {
	sweeper := newStagingSweeper(testLogger())

	assert.True(t, sweeper.due("/photos"))
	assert.False(t, sweeper.due("/photos"))
	assert.True(t, sweeper.due("/documents"))
}
