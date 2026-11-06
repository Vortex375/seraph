package taglib

import (
	"context"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"golang.org/x/net/webdav"
)

func openFileRef(t *testing.T, name string) FileRef {
	file, err := webdav.Dir("testdata").OpenFile(context.Background(), name, os.O_RDONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	stream := NewWebdavFileStream(name, file)
	t.Cleanup(stream.Delete)
	ref := NewFileRef(stream)
	t.Cleanup(func() { DeleteFileRef(ref) })
	return ref
}

// testdata/cover.jpg is embedded in both fixtures; like every JPEG it has a
// NUL byte within its first bytes, which a strlen-based conversion cuts off.
func TestEmbeddedPictureIsReadByteExact(t *testing.T) {
	cover, err := os.ReadFile("testdata/cover.jpg")
	if err != nil {
		t.Fatal(err)
	}
	assert.Contains(t, string(cover[:8]), "\x00")

	for _, name := range []string{"picture.mp3", "picture.flac"} {
		t.Run(name, func(t *testing.T) {
			pictures := Pictures(openFileRef(t, name))

			if assert.Len(t, pictures, 1) {
				assert.Equal(t, "image/jpeg", pictures[0].MimeType)
				assert.Equal(t, "Front Cover", pictures[0].PictureType)
				assert.Equal(t, cover, pictures[0].Data)
			}
		})
	}
}

func TestFileWithoutPictureHasNone(t *testing.T) {
	file, err := webdav.Dir(".").OpenFile(context.Background(), "test.mp3", os.O_RDONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	stream := NewWebdavFileStream("test.mp3", file)
	defer stream.Delete()
	ref := NewFileRef(stream)
	defer DeleteFileRef(ref)

	assert.Empty(t, Pictures(ref))
}

func TestNonAsciiTagsReadAsUtf8(t *testing.T) {
	for _, name := range []string{"picture.mp3", "picture.flac"} {
		t.Run(name, func(t *testing.T) {
			tag := openFileRef(t, name).Tag()
			title := tag.Title()
			defer DeleteString(title)
			artist := tag.Artist()
			defer DeleteString(artist)

			assert.Equal(t, "Jóga", title.ToCString(true))
			assert.Equal(t, "Björk", artist.ToCString(true))
		})
	}
}

func TestReadTags(t *testing.T) {
	file, err := webdav.Dir(".").OpenFile(context.Background(), "test.mp3", os.O_RDONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	stream := NewWebdavFileStream("test.mp3", file)
	defer stream.Delete()
	ref := NewFileRef(stream)
	defer DeleteFileRef(ref)

	tags := ReadTags(ref)
	assert.Equal(t, "The Title", tags.Title)
	assert.Equal(t, "The Artist", tags.Artist)
	assert.Equal(t, "The Album", tags.Album)
	assert.Equal(t, "Booty Bass", tags.Genre)
	assert.Equal(t, 42, tags.TrackNumber)
	assert.Greater(t, tags.DurationMs, int64(0))

	utf := ReadTags(openFileRef(t, "picture.flac"))
	assert.Equal(t, "Jóga", utf.Title)
	assert.Equal(t, "Homogenic", utf.Album)
}

func TestLeadingNumber(t *testing.T) {
	assert.Equal(t, 2, leadingNumber("2/3"))
	assert.Equal(t, 1, leadingNumber("1"))
	assert.Equal(t, 0, leadingNumber(""))
	assert.Equal(t, 0, leadingNumber("A"))
}
