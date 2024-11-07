package util

import "io"

const bufferSize = 512 * 1024

type FastReader struct {
	io.Reader
}

// implements WriterTo
var _ io.WriterTo = &FastReader{}

func (r *FastReader) WriteTo(w io.Writer) (n int64, err error) {
	buf := make([]byte, bufferSize)

	return io.CopyBuffer(w, r.Reader, buf)
}
