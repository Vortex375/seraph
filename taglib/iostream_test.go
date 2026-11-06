package taglib

import (
	"context"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"golang.org/x/net/webdav"
)

// Calls go through the C++ IOStream (SwigcptrIOStream), which dispatches
// back to the Go director - the path TagLib itself takes.
func TestWebdavFileStreamPositions(t *testing.T) {
	cover, err := os.ReadFile("testdata/cover.jpg")
	if err != nil {
		t.Fatal(err)
	}
	file, err := webdav.Dir("testdata").OpenFile(context.Background(), "cover.jpg", os.O_RDONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	stream := NewWebdavFileStream("cover.jpg", file)
	defer stream.Delete()
	cpp := SwigcptrIOStream(stream.Swigcptr())

	assert.Equal(t, int64(len(cover)), cpp.Length())
	assert.Equal(t, int64(0), cpp.Tell())

	block := cpp.ReadBlock(10)
	assert.Equal(t, cover[:10], []byte(block.Bytes()))
	DeleteByteVector(block)
	assert.Equal(t, int64(10), cpp.Tell(), "reading advances the position")

	cpp.Seek(int64(-4), IOStreamEnd)
	assert.Equal(t, int64(len(cover)-4), cpp.Tell())

	block = cpp.ReadBlock(100)
	assert.Equal(t, cover[len(cover)-4:], []byte(block.Bytes()), "short read at the end")
	DeleteByteVector(block)
	assert.Equal(t, int64(len(cover)), cpp.Tell())

	block = cpp.ReadBlock(100)
	assert.Equal(t, uint(0), block.Size(), "read past the end is empty")
	DeleteByteVector(block)
}
