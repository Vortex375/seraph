package taglib

import (
	"context"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"golang.org/x/net/webdav"
)

func TestWebdavFileStream(t *testing.T) {
	dir := webdav.Dir(".")
	file, err := dir.OpenFile(context.Background(), "test.mp3", os.O_RDONLY, 0)

	if err != nil {
		t.Fatal(err)
	}

	stream := NewWebdavFileStream("test.mp3", file)
	defer stream.Delete()

	ref := NewFileRef(stream)
	defer DeleteFileRef(ref)

	tag := ref.Tag()
	title := tag.Title()
	artist := tag.Artist()
	album := tag.Album()

	assert.Equal(t, "The Title", title.ToCString())
	assert.Equal(t, "The Artist", artist.ToCString())
	assert.Equal(t, "The Album", album.ToCString())

	props := ref.Properties()
	genre := props.Value(NewString("genre"))
	comment := props.Value(NewString("comment"))
	tracknr := props.Value(NewString("tracknumber"))

	assert.Equal(t, "Booty Bass", genre.ToString().ToCString())
	assert.Equal(t, "A Comment", comment.ToString().ToCString())
	assert.Equal(t, "42", tracknr.ToString().ToCString())
}
