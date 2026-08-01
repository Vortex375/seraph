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
	"image/color"
	"image/jpeg"
	"log/slog"
	"os"
	"path"
	"path/filepath"
	"testing"

	"github.com/disintegration/imaging"
	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/stretchr/testify/assert"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/events"
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
	opts := &server.Options{
		JetStream: true,
		StoreDir:  os.TempDir(),
	}
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
	return getThumbnailerWithOptions(t, nil)
}

func getThumbnailerWithOptions(t *testing.T, options *Options) (*Thumbnailer, *nats.Conn) {
	thumb, nc, _ := getThumbnailerWithJetStream(t, options)
	return thumb, nc
}

// getThumbnailerWithJetStream is like getThumbnailerWithOptions but also
// returns the jetstream.JetStream handle backing the Thumbnailer, for tests
// that need to publish FileChangedEvents or inspect/manipulate the durable
// consumer directly.
func getThumbnailerWithJetStream(t *testing.T, options *Options) (*Thumbnailer, *nats.Conn, jetstream.JetStream) {
	nc, err := nats.Connect(natsServer.ClientURL())
	if err != nil {
		t.Error(err)
		t.FailNow()
	}

	js, err := jetstream.New(nc)
	if err != nil {
		t.Fatal(err)
	}

	logger := logging.New(logging.Params{})
	logger.SetLevel(slog.LevelDebug)

	res, _ := NewThumbnailer(Params{
		Nc:      nc,
		Js:      js,
		Tracing: tracing.NewNoopTracing(),
		Logger:  logger,
		Options: options,
	}, "test", "", tmpFs)

	err = res.Thumbnailer.Start()
	if err != nil {
		t.Fatal(err)
	}

	return res.Thumbnailer, nc, js
}

// resetInvalidationStream removes the durable file-change stream (if any)
// so each invalidation test starts from a clean slate: the durable consumer
// name is fixed (invalidationConsumerName), so stream state would otherwise
// leak between tests in this package.
func resetInvalidationStream(t *testing.T, js jetstream.JetStream) {
	t.Helper()
	t.Cleanup(func() {
		_ = js.DeleteStream(context.Background(), events.FileChangedStream)
	})
}

// publishFileChanged publishes a FileChangedEvent on the durable file-change
// stream/topic, creating the stream first if it does not exist yet - mirroring
// how file-indexer (the real producer) does it.
func publishFileChanged(t *testing.T, js jetstream.JetStream, ev events.FileChangedEvent) {
	t.Helper()

	_, err := js.CreateOrUpdateStream(context.Background(), jetstream.StreamConfig{
		Name:     events.FileChangedStream,
		Subjects: []string{events.FileChangedTopic},
	})
	if err != nil {
		t.Fatal(err)
	}

	data, err := ev.Marshal()
	if err != nil {
		t.Fatal(err)
	}

	topic := fmt.Sprintf(events.FileChangedTopicPattern, ev.FileID)
	_, err = js.Publish(context.Background(), topic, data)
	if err != nil {
		t.Fatal(err)
	}
}

// writeFixtureJpeg writes a solid-color JPEG of the given dimensions into the
// directory served as the "testinput" file provider, returning its file name.
// The caller is responsible for removing the file once the test completes.
func writeFixtureJpeg(t *testing.T, name string, width, height int) string {
	t.Helper()

	img := imaging.New(width, height, color.NRGBA{R: 200, G: 100, B: 50, A: 255})

	f, err := os.Create(filepath.Join(".", name))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	err = jpeg.Encode(f, img, &jpeg.Options{Quality: jpeg.DefaultQuality})
	if err != nil {
		t.Fatal(err)
	}

	t.Cleanup(func() {
		os.Remove(filepath.Join(".", name))
	})

	return name
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

func TestCreateThumbnailWithinConfiguredCap(t *testing.T) {
	// use a small configured cap so the fixture images stay cheap to generate
	options := &Options{
		JpegQuality:    jpeg.DefaultQuality,
		Parallel:       1,
		MaxImageWidth:  100,
		MaxImageHeight: 100,
	}
	thumbnailer, nc := getThumbnailerWithOptions(t, options)
	defer thumbnailer.Stop()

	name := writeFixtureJpeg(t, "fixture_within_cap.jpg", 100, 100)

	req := ThumbnailRequest{
		ProviderID: "testinput",
		Path:       name,
		Width:      64,
		Height:     64,
	}
	resp := ThumbnailResponse{}

	err := messaging.Request(context.Background(), nc, ThumbnailRequestTopic, &req, &resp)
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", resp.Error)
	assert.Equal(t, "", resp.ErrorClass)
	assert.NotEmpty(t, resp.Path)
}

func TestCreateThumbnailBeyondConfiguredCapIsRefused(t *testing.T) {
	options := &Options{
		JpegQuality:    jpeg.DefaultQuality,
		Parallel:       1,
		MaxImageWidth:  100,
		MaxImageHeight: 100,
	}
	thumbnailer, nc := getThumbnailerWithOptions(t, options)
	defer thumbnailer.Stop()

	name := writeFixtureJpeg(t, "fixture_beyond_cap.jpg", 101, 101)

	req := ThumbnailRequest{
		ProviderID: "testinput",
		Path:       name,
		Width:      64,
		Height:     64,
	}
	resp := ThumbnailResponse{}

	err := messaging.Request(context.Background(), nc, ThumbnailRequestTopic, &req, &resp)
	if err != nil {
		t.Fatal(err)
	}

	assert.NotEqual(t, "", resp.Error)
	assert.Equal(t, ErrorClassTooLarge, resp.ErrorClass)
	assert.Empty(t, resp.Path)
}

func TestDefaultCapCoversFlagshipPhoneResolutions(t *testing.T) {
	// Samsung's 200 MP mode: 16320x12240. 108 MP mode: 12000x9000. The
	// documented default must clear both without configuration.
	assert.GreaterOrEqual(t, DefaultMaxImageWidth, 16320)
	assert.GreaterOrEqual(t, DefaultMaxImageHeight, 12240)
}

func TestImageBeyondOldHardcodedCapNowProducesThumbnail(t *testing.T) {
	// 8200x8200 exceeds the old hardcoded 8120x8120 cap that this ticket
	// replaces. Under the (raised, configurable) default it must now
	// succeed instead of being rejected outright.
	thumbnailer, nc := getThumbnailer(t)
	defer thumbnailer.Stop()

	name := writeFixtureJpeg(t, "fixture_beyond_old_cap.jpg", 8200, 8200)

	req := ThumbnailRequest{
		ProviderID: "testinput",
		Path:       name,
		Width:      64,
		Height:     64,
	}
	resp := ThumbnailResponse{}

	err := messaging.Request(context.Background(), nc, ThumbnailRequestTopic, &req, &resp)
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", resp.Error)
	assert.Equal(t, "", resp.ErrorClass)
	assert.NotEmpty(t, resp.Path)
}

func TestUnsupportedFormatIsDistinguishableFromCorruptOrTooLarge(t *testing.T) {
	thumbnailer, nc := getThumbnailer(t)
	defer thumbnailer.Stop()

	name := "fixture_unsupported.txt"
	err := os.WriteFile(filepath.Join(".", name), []byte("this is not an image"), 0644)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Remove(filepath.Join(".", name)) })

	req := ThumbnailRequest{
		ProviderID: "testinput",
		Path:       name,
		Width:      64,
		Height:     64,
	}
	resp := ThumbnailResponse{}

	reqErr := messaging.Request(context.Background(), nc, ThumbnailRequestTopic, &req, &resp)
	if reqErr != nil {
		t.Fatal(reqErr)
	}

	assert.NotEqual(t, "", resp.Error)
	assert.Equal(t, ErrorClassUnsupportedFormat, resp.ErrorClass)
	assert.NotEqual(t, ErrorClassTooLarge, resp.ErrorClass)
}

func TestCorruptImageIsDistinguishableFromUnsupportedOrTooLarge(t *testing.T) {
	thumbnailer, nc := getThumbnailer(t)
	defer thumbnailer.Stop()

	// valid JPEG SOI marker followed by garbage: recognized as JPEG format,
	// but not decodable.
	name := "fixture_corrupt.jpg"
	corrupt := append([]byte{0xFF, 0xD8, 0xFF, 0xE0}, []byte("not actually a jpeg body, just garbage bytes to fail mid-decode")...)
	err := os.WriteFile(filepath.Join(".", name), corrupt, 0644)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Remove(filepath.Join(".", name)) })

	req := ThumbnailRequest{
		ProviderID: "testinput",
		Path:       name,
		Width:      64,
		Height:     64,
	}
	resp := ThumbnailResponse{}

	reqErr := messaging.Request(context.Background(), nc, ThumbnailRequestTopic, &req, &resp)
	if reqErr != nil {
		t.Fatal(reqErr)
	}

	assert.NotEqual(t, "", resp.Error)
	assert.Equal(t, ErrorClassCorrupt, resp.ErrorClass)
	assert.NotEqual(t, ErrorClassTooLarge, resp.ErrorClass)
	assert.NotEqual(t, ErrorClassUnsupportedFormat, resp.ErrorClass)
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
