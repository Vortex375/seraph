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

package tagreader

import (
	"context"
	"os"
	"testing"

	"github.com/stretchr/testify/assert"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/audio-metadata/audiometadata"
)

// testdata: tagged.mp3 (no picture), picture.mp3 (cover.jpg embedded as
// front cover) and not-audio.txt.
func localReader() *Reader {
	return NewReader(func(ctx context.Context, _ string, path string) (webdav.File, error) {
		return webdav.Dir("testdata").OpenFile(ctx, path, os.O_RDONLY, 0)
	})
}

func TestTags(t *testing.T) {
	tags := localReader().Tags(context.Background(), "p", "tagged.mp3")

	assert.Empty(t, tags.Error)
	assert.Equal(t, "The Title", tags.Title)
	assert.Equal(t, "The Artist", tags.Artist)
	assert.Equal(t, "The Album", tags.Album)
	assert.Equal(t, "Booty Bass", tags.Genre)
	assert.Equal(t, 42, tags.TrackNumber)
	assert.Greater(t, tags.DurationMs, int64(0))
	assert.False(t, tags.HasPicture)

	withPicture := localReader().Tags(context.Background(), "p", "picture.mp3")
	assert.Equal(t, "Jóga", withPicture.Title)
	assert.True(t, withPicture.HasPicture)
}

func TestTagsErrors(t *testing.T) {
	r := localReader()
	assert.Equal(t, audiometadata.ErrorClassUnsupported, r.Tags(context.Background(), "p", "not-audio.txt").ErrorClass)
	assert.Equal(t, audiometadata.ErrorClassNotFound, r.Tags(context.Background(), "p", "missing.mp3").ErrorClass)
}

func TestPicture(t *testing.T) {
	cover, err := os.ReadFile("testdata/cover.jpg")
	if err != nil {
		t.Fatal(err)
	}
	r := localReader()

	whole := r.Picture(context.Background(), "p", "picture.mp3", 0, audiometadata.MaxPictureChunk)
	assert.Empty(t, whole.Error)
	assert.Equal(t, "image/jpeg", whole.MimeType)
	assert.Equal(t, int64(len(cover)), whole.TotalSize)
	assert.Equal(t, cover, whole.Data)

	part := r.Picture(context.Background(), "p", "picture.mp3", 10, 20)
	assert.Equal(t, cover[10:30], part.Data)

	past := r.Picture(context.Background(), "p", "picture.mp3", int64(len(cover)), 20)
	assert.Empty(t, past.Data)

	none := r.Picture(context.Background(), "p", "tagged.mp3", 0, 100)
	assert.Equal(t, audiometadata.ErrorClassNoPicture, none.ErrorClass)
}

func TestChunkIsCapped(t *testing.T) {
	data := make([]byte, audiometadata.MaxPictureChunk*2)
	assert.Len(t, chunk(data, 0, len(data)), audiometadata.MaxPictureChunk)
	assert.Empty(t, chunk(data, -1, 10))
}
