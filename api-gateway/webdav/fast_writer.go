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

package webdav

import (
	"io"

	"github.com/gin-gonic/gin"
)

// makes GET requests faster by using a larger buffer size than the default 32kb of io.CopyN()
type fastResponseWriter struct {
	gin.ResponseWriter
}

const responseBufferSize = 512 * 1024

func (w *fastResponseWriter) ReadFrom(r io.Reader) (n int64, err error) {
	size := responseBufferSize

	if l, ok := r.(*io.LimitedReader); ok && int64(responseBufferSize) > l.N {
		if l.N < 1 {
			size = 1
		} else {
			size = int(l.N)
		}
	}

	buf := make([]byte, size)

	return io.CopyBuffer(w.ResponseWriter, r, buf)
}
