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
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/audio-metadata/audiometadata"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/tracing"
)

// Reads go through the File Provider over NATS, like in the service: the test
// starts a real NATS server and a dir-backed File Provider serving testdata.
func TestRoundTrip(t *testing.T) {
	// the provider serves a copy of testdata plus a generated large-cover.mp3
	dir := t.TempDir()
	require.NoError(t, os.CopyFS(dir, os.DirFS("testdata")))
	writeLargeCoverMp3(t, dir)

	natsServer, err := server.NewServer(&server.Options{
		Host:   "127.0.0.1",
		Port:   -1,
		NoLog:  true,
		NoSigs: true,
	})
	require.NoError(t, err)
	natsServer.Start()
	defer natsServer.Shutdown()

	var nc *nats.Conn
	nc, err = nats.Connect(natsServer.ClientURL())
	require.NoError(t, err)
	defer nc.Close()

	logger := logging.New(logging.Params{})
	provider, err := fileprovider.NewFileProviderServer(fileprovider.ServerParams{
		Nc:      nc,
		Logger:  logger,
		Tracing: tracing.NewNoopTracing(),
	}, "testdata", webdav.Dir(dir), true)
	require.NoError(t, err)
	require.NoError(t, provider.Start())
	defer provider.Stop(true)

	responder := NewResponder(nc, logger, NewReader(ProviderOpener(nc, logger)))
	require.NoError(t, responder.Start())
	defer responder.Stop()

	t.Run("tagged file", func(t *testing.T) {
		res := tagsRequest(t, nc, "/tagged.mp3")

		assert.Empty(t, res.Error)
		assert.Empty(t, res.ErrorClass)
		assert.Equal(t, "The Title", res.Title)
		assert.Equal(t, "The Artist", res.Artist)
		assert.Equal(t, "The Album", res.Album)
	})

	t.Run("not found", func(t *testing.T) {
		res := tagsRequest(t, nc, "/missing.mp3")
		assert.Equal(t, audiometadata.ErrorClassNotFound, res.ErrorClass, res.Error)
	})

	t.Run("not audio", func(t *testing.T) {
		res := tagsRequest(t, nc, "/not-audio.txt")
		assert.Equal(t, audiometadata.ErrorClassUnsupported, res.ErrorClass, res.Error)
	})

	t.Run("directory", func(t *testing.T) {
		res := tagsRequest(t, nc, "/")
		assert.Equal(t, audiometadata.ErrorClassUnsupported, res.ErrorClass, res.Error)
	})

	t.Run("picture larger than a chunk", func(t *testing.T) {
		data, mimeType, err := audiometadata.ReadPicture(context.Background(), nc, "testdata", "/large-cover.mp3")
		require.NoError(t, err)
		assert.Equal(t, "image/png", mimeType)
		assert.Equal(t, largeCover, data)
	})

	t.Run("no picture", func(t *testing.T) {
		_, _, err := audiometadata.ReadPicture(context.Background(), nc, "testdata", "/tagged.mp3")
		var e *audiometadata.Error
		require.ErrorAs(t, err, &e)
		assert.Equal(t, audiometadata.ErrorClassNoPicture, e.Class)
	})
}

func tagsRequest(t *testing.T, nc *nats.Conn, path string) audiometadata.TagsResponse {
	t.Helper()
	res := audiometadata.TagsResponse{}
	require.NoError(t, messaging.Request(context.Background(), nc, audiometadata.TagsRequestTopic,
		&audiometadata.TagsRequest{ProviderID: "testdata", Path: path}, &res))
	return res
}

// largeCover is a picture spanning three MaxPictureChunk chunks (not a
// valid PNG - TagLib does not decode pictures).
var largeCover = func() []byte {
	b := make([]byte, audiometadata.MaxPictureChunk*2+12345)
	for i := range b {
		b[i] = byte(i * 7)
	}
	return b
}()

// writeLargeCoverMp3 writes dir/large-cover.mp3: an ID3v2.3 tag holding only
// an APIC frame with largeCover, followed by tagged.mp3.
func writeLargeCoverMp3(t *testing.T, dir string) {
	t.Helper()
	audio, err := os.ReadFile("testdata/tagged.mp3")
	require.NoError(t, err)

	// APIC: encoding, mime type, picture type (3 = front cover), description
	frame := append([]byte("\x00image/png\x00\x03\x00"), largeCover...)
	header := []byte("APIC")
	header = binary.BigEndian.AppendUint32(header, uint32(len(frame)))
	header = append(header, 0, 0)
	body := append(header, frame...)

	n := len(body) // ID3v2 tag size is syncsafe: 7 bits per byte
	tag := []byte{'I', 'D', '3', 3, 0, 0, byte(n >> 21 & 0x7f), byte(n >> 14 & 0x7f), byte(n >> 7 & 0x7f), byte(n & 0x7f)}
	tag = append(tag, body...)

	require.NoError(t, os.WriteFile(filepath.Join(dir, "large-cover.mp3"), append(tag, audio...), 0o644))
}
