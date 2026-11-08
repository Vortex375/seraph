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
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"golang.org/x/net/webdav"
)

// Every upload sends a MKCOL for its parent first; concurrent uploads into one
// folder must not fail on the handler's lock for that MKCOL.
func TestConcurrentMkcolOnExistingCollection(t *testing.T) {
	dir := t.TempDir()
	require.NoError(t, os.Mkdir(filepath.Join(dir, "photos"), 0777))
	handler := withExistingCollectionMkcol(&webdav.Handler{
		FileSystem: newTestFs(dir),
		LockSystem: webdav.NewMemLS(),
	})

	const n = 200
	codes := make([]int, n)
	var wg sync.WaitGroup
	for i := range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rec := httptest.NewRecorder()
			handler.ServeHTTP(rec, httptest.NewRequest("MKCOL", "/photos/", nil))
			codes[i] = rec.Code
		}()
	}
	wg.Wait()

	for _, c := range codes {
		assert.Equal(t, http.StatusMethodNotAllowed, c)
	}

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest("MKCOL", "/new/", nil))
	assert.Equal(t, http.StatusCreated, rec.Code)
}
