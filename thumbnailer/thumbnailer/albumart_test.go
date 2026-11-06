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

package thumbnailer

import (
	"context"
	"image"
	_ "image/jpeg"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/audio-metadata/audiometadata"
	"umbasa.net/seraph/messaging"
)

// fakeAudioMetadata answers PictureRequestTopic like audio-metadata: a file
// named "*embedded.mp3" has sample.jpg embedded, other ".mp3"s have no
// picture, anything else is unsupported. Chunks are served honestly, so a
// cover larger than one chunk is read in several requests.
func fakeAudioMetadata(t *testing.T, nc *nats.Conn) {
	sample, err := os.ReadFile("sample.jpg")
	require.NoError(t, err)

	sub, err := nc.Subscribe(audiometadata.PictureRequestTopic, func(msg *nats.Msg) {
		req := audiometadata.PictureRequest{}
		_ = req.Unmarshal(msg.Data)
		var resp audiometadata.PictureResponse
		switch {
		case strings.HasSuffix(req.Path, "embedded.mp3"):
			end := min(req.Offset+int64(min(int(req.Length), audiometadata.MaxPictureChunk)), int64(len(sample)))
			resp = audiometadata.PictureResponse{MimeType: "image/jpeg", TotalSize: int64(len(sample)), Data: sample[req.Offset:end]}
		case strings.HasSuffix(req.Path, ".mp3"):
			resp = audiometadata.PictureResponse{Error: "no embedded picture", ErrorClass: audiometadata.ErrorClassNoPicture}
		default:
			resp = audiometadata.PictureResponse{Error: "not a supported audio file", ErrorClass: audiometadata.ErrorClassUnsupported}
		}
		data, _ := resp.Marshal()
		msg.Respond(data)
	})
	require.NoError(t, err)
	t.Cleanup(func() { sub.Unsubscribe() })
}

// writeFixtures creates files (relative to the test provider's root) and
// removes them afterwards.
func writeFixtures(t *testing.T, files map[string][]byte) {
	for name, data := range files {
		require.NoError(t, os.MkdirAll(filepath.Dir(name), 0o755))
		require.NoError(t, os.WriteFile(name, data, 0o644))
	}
	t.Cleanup(func() {
		for name := range files {
			os.Remove(name)
			os.Remove(filepath.Dir(name)) // only once empty
		}
	})
}

func requestAlbumArt(t *testing.T, nc *nats.Conn, name string) ThumbnailResponse {
	req := ThumbnailRequest{ProviderID: "testinput", Path: name, Width: 64, Height: 64}
	resp := ThumbnailResponse{}
	require.NoError(t, messaging.Request(context.Background(), nc, ThumbnailRequestTopic, &req, &resp))
	return resp
}

func assertThumbnailImage(t *testing.T, resp ThumbnailResponse) {
	require.Empty(t, resp.Error)
	f, err := os.Open(filepath.Join(tmpDir, resp.Path))
	require.NoError(t, err)
	defer f.Close()
	_, format, err := image.Decode(f)
	require.NoError(t, err)
	assert.Equal(t, "jpeg", format)
}

func TestAlbumArt(t *testing.T) {
	thumbnailer, nc := getThumbnailer(t)
	defer thumbnailer.Stop()
	fakeAudioMetadata(t, nc)

	sample, err := os.ReadFile("sample.jpg")
	require.NoError(t, err)
	notAnImage := []byte("ID3 not an image")
	writeFixtures(t, map[string][]byte{
		"albumart-embedded/embedded.mp3": notAnImage,
		"albumart-folder/song.mp3":       notAnImage,
		"albumart-folder/Cover.JPG":      sample,
		"albumart-folder/notes.txt":      []byte("not a cover"),
		"albumart-none/song.mp3":         notAnImage,
		"albumart-none/booklet.jpg":      sample, // not a cover name
		"albumart-other/document.pdf":    notAnImage,
		"albumart-other/cover.jpg":       sample,
	})

	t.Run("embedded picture", func(t *testing.T) {
		assertThumbnailImage(t, requestAlbumArt(t, nc, "albumart-embedded/embedded.mp3"))
	})

	t.Run("folder cover, case-insensitive", func(t *testing.T) {
		assertThumbnailImage(t, requestAlbumArt(t, nc, "albumart-folder/song.mp3"))
	})

	t.Run("audio without art is unsupported", func(t *testing.T) {
		resp := requestAlbumArt(t, nc, "albumart-none/song.mp3")
		assert.Equal(t, ErrorClassUnsupportedFormat, resp.ErrorClass, resp.Error)
	})

	t.Run("non-audio file ignores the folder cover", func(t *testing.T) {
		resp := requestAlbumArt(t, nc, "albumart-other/document.pdf")
		assert.Equal(t, ErrorClassUnsupportedFormat, resp.ErrorClass, resp.Error)
	})
}

func TestFolderCoverPriority(t *testing.T) {
	writeFixtures(t, map[string][]byte{
		"albumart-priority/album.png":  {1},
		"albumart-priority/front.jpeg": {1},
		"albumart-priority/folder.jpg": {1},
	})
	cover, ok := folderCover(context.Background(), &client{webdav.Dir(".")}, "albumart-priority")
	assert.True(t, ok)
	assert.Equal(t, "albumart-priority/folder.jpg", cover)
}
