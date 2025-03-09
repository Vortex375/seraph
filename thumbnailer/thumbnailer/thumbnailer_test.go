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
	"fmt"
	"image"
	"log/slog"
	"os"
	"path"
	"path/filepath"
	"testing"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/tracing"
)

var natsServer *server.Server
var fileServer *fileprovider.FileProviderServer
var tmpDir string
var tmpFs fileprovider.Client

// implement fileprovider.Client
type client struct {
	webdav.Dir
}

func (*client) Close() {}

func TestMain(m *testing.M) {
	setup()

	code := m.Run()

	shutdown()

	os.Exit(code)
}

func setup() {
	opts := &server.Options{}
	var err error
	natsServer, err = server.NewServer(opts)

	natsServer.Start()

	if err != nil {
		panic(err)
	}

	tmpDir, err = os.MkdirTemp("", "seraph-thumbnailer-test-")

	if err != nil {
		panic(err)
	}

	tmpFs = &client{webdav.Dir(tmpDir)}

	nc, err := nats.Connect(natsServer.ClientURL())
	if err != nil {
		panic(err)
	}

	logger := logging.New(logging.Params{})
	logger.SetLevel(slog.LevelDebug)

	params := fileprovider.ServerParams{
		Nc:      nc,
		Tracing: tracing.NewNoopTracing(),
		Logger:  logger,
	}

	fileServer, err = fileprovider.NewFileProviderServer(params, "testinput", webdav.Dir("."), true)
	if err != nil {
		panic(err)
	}
	fileServer.Start()
}

func shutdown() {
	if fileServer != nil {
		fileServer.Stop(true)
		fileServer = nil
	}
	if natsServer != nil {
		natsServer.Shutdown()
		natsServer = nil
	}

	if tmpDir != "" {
		os.RemoveAll(tmpDir)
	}
}

func getThumbnailer(t *testing.T) (*Thumbnailer, *nats.Conn) {
	nc, err := nats.Connect(natsServer.ClientURL())
	if err != nil {
		t.Error(err)
		t.FailNow()
	}

	logger := logging.New(logging.Params{})
	logger.SetLevel(slog.LevelDebug)

	res, _ := NewThumbnailer(Params{
		Nc:      nc,
		Tracing: tracing.NewNoopTracing(),
		Logger:  logger,
	}, "test", "", tmpFs)

	err = res.Thumbnailer.Start()
	if err != nil {
		t.Fatal(err)
	}

	return res.Thumbnailer, nc
}

func TestCreateThumbnail(t *testing.T) {
	thumbnailer, nc := getThumbnailer(t)
	defer thumbnailer.Stop()

	req := ThumbnailRequest{
		ProviderID: "testinput",
		Path:       "sample.jpg",
		Width:      1024,
		Height:     1024,
	}
	resp := ThumbnailResponse{}

	err := messaging.Request(context.Background(), nc, ThumbnailRequestTopic, &req, &resp)
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", resp.Error)
	assert.Equal(t, fmt.Sprintf("%s_1024x1024.jpg", ThumbnailHash(path.Join(req.ProviderID, req.Path))), resp.Path)

	resultFile, err := os.OpenFile(filepath.Join(tmpDir, resp.Path), os.O_RDONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer resultFile.Close()

	resultImage, format, err := image.Decode(resultFile)
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "jpeg", format)
	assert.Equal(t, 1024, resultImage.Bounds().Size().X)
	assert.Equal(t, 771, resultImage.Bounds().Size().Y)

	t.Log(tmpDir)
}

func TestFitSize(t *testing.T) {
	sizes := []int{1, 15, 64, 80, 128, 180, 256, 270, 300, 512, 513, 1024, 9000}
	/* should fit the next-largest thumbnail size */
	expected := []int{128, 128, 128, 128, 128, 256, 256, 512, 512, 512, 1024, 1024, 1024}

	assert.Equal(t, len(sizes), len(expected))

	for i, _ := range sizes {
		assert.Equal(t, expected[i], fitSize(sizes[i]), "real value: %d", sizes[i])
	}
}
