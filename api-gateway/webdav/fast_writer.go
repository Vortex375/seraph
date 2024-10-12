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
