package thumbnailer

import (
	"fmt"
	"image"
	"log/slog"
	"os"
	"path"
	"path/filepath"
	"testing"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"
)

var natsServer *server.Server
var tmpDir string
var tmpFs webdav.FileSystem

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

	tmpFs = webdav.Dir(tmpDir)

	nc, err := nats.Connect(natsServer.ClientURL())
	if err != nil {
		panic(err)
	}

	logger := logging.New(logging.Params{})
	logger.SetLevel(slog.LevelDebug)

	fileprovider.NewFileProviderServer("testinput", nc, webdav.Dir("."), true, logger)
}

func shutdown() {
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
		Nc:     nc,
		Logger: logger,
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

	reqData, err := req.Marshal()
	if err != nil {
		t.Fatal(err)
	}

	respData, err := nc.Request(ThumbnailRequestTopic, reqData, 10*time.Second)
	if err != nil {
		t.Fatal(err)
	}

	resp := ThumbnailResponse{}
	err = resp.Unmarshal(respData.Data)

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
