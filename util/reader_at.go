package util

import "io"

type ReaderAt struct {
	io.ReadSeeker
}

// implements io.ReaderAt
var _ io.ReaderAt = &ReaderAt{}

func (r *ReaderAt) ReadAt(p []byte, off int64) (n int, err error) {
	if _, err := r.ReadSeeker.Seek(off, io.SeekStart); err != nil {
		return 0, err
	}

	read := 0
	for read < len(p) {
		readN, err := r.ReadSeeker.Read(p)
		read += readN
		if err != nil {
			return read, err
		}
		p = p[readN:]
	}
	return read, nil
}
