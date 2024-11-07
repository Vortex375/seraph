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
	"bufio"
	"context"
	"errors"
	"fmt"
	"image"
	"io"
	"log/slog"
	"math/rand"
	"os"
	"path"
	"runtime"
	"strconv"
	"time"

	"github.com/disintegration/imaging"
	"github.com/nats-io/nats.go"
	"go.uber.org/fx"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/util"

	_ "image/gif"
	"image/jpeg"
	_ "image/png"
)

const ThumbnailRequestTopic = "seraph.thumbnail.request"

// maximum acceptable source image size for thumbnail creation
const MaxImageWidth = 8120
const MaxImageHeight = 8120

// common thumbnail sizes in pixels
var ThumbnailSizes = []int{128, 256, 512, 1024}

const DefaultThumbnailSize = 256

// content type for thumbnails
const ContentType = "image/jpeg"

// name of temporary folder where thumb files are put during creation
const tmpFolderName = "_tmp"

type Params struct {
	fx.In

	Nc      *nats.Conn
	Logger  *logging.Logger
	Options *Options `optional:"true"`
}

type Options struct {
	JpegQuality int
	Parallel    int
}

type Result struct {
	fx.Out

	Thumbnailer *Thumbnailer
}

type Thumbnailer struct {
	options          Options
	logging          *logging.Logger
	log              *slog.Logger
	nc               *nats.Conn
	fileProviderId   string
	path             string
	thumbnailStorage fileprovider.Client
	sub              *nats.Subscription
	requestChan      chan *nats.Msg
	limiter          util.Limiter
}

func NewThumbnailer(p Params, fileProviderId string, path string, thumbnailStorage fileprovider.Client) (Result, error) {
	var options *Options
	if p.Options == nil {
		options = &Options{
			JpegQuality: jpeg.DefaultQuality,
			Parallel:    runtime.NumCPU(),
		}
	} else {
		options = p.Options
	}
	return Result{
		Thumbnailer: &Thumbnailer{
			options:          *options,
			logging:          p.Logger,
			log:              p.Logger.GetLogger("thumbnailer"),
			nc:               p.Nc,
			fileProviderId:   fileProviderId,
			path:             path,
			thumbnailStorage: thumbnailStorage,
		},
	}, nil
}

func (t *Thumbnailer) Start() error {
	if t.path != "" {
		//TODO: doesn't work because it's not recursive
		err := t.thumbnailStorage.Mkdir(context.TODO(), t.path, 0777)
		if err != nil {
			return err
		}
	}
	t.thumbnailStorage.Mkdir(context.TODO(), path.Join(t.path, tmpFolderName), 0777)

	t.limiter = util.NewLimiter(t.options.Parallel)
	t.requestChan = make(chan *nats.Msg, nats.DefaultSubPendingMsgsLimit)

	sub, err := t.nc.ChanQueueSubscribe(ThumbnailRequestTopic, ThumbnailRequestTopic, t.requestChan)
	if err != nil {
		return err
	}
	t.sub = sub

	go t.messageLoop()

	return nil
}

func (t *Thumbnailer) Stop() error {
	var err error
	if t.sub != nil {
		err = t.sub.Unsubscribe()
		t.sub = nil
	}
	if t.requestChan != nil {
		close(t.requestChan)
		t.requestChan = nil
	}
	if t.limiter != nil {
		t.limiter.CancelAll()
		t.limiter = nil
	}
	return err
}

func (t *Thumbnailer) messageLoop() {
	for {
		msg, ok := <-t.requestChan
		if !ok {
			return
		}

		go t.handleMessage(msg)
	}
}

func (t *Thumbnailer) handleMessage(msg *nats.Msg) {
	req := ThumbnailRequest{}
	req.Unmarshal(msg.Data)

	resp := t.handleRequest(req)

	data, _ := resp.Marshal()

	msg.Respond(data)
}

func (t *Thumbnailer) handleRequest(req ThumbnailRequest) (resp ThumbnailResponse) {
	if req.ProviderID == "" {
		resp.Error = "invalid empty providerId"
		return
	}
	if req.Path == "" {
		resp.Error = "invalid empty path"
		return
	}

	if req.Width == 0 {
		req.Width = DefaultThumbnailSize
	}
	if req.Height == 0 {
		req.Height = DefaultThumbnailSize
	}
	if !req.Exact {
		req.Width = fitSize(req.Width)
		req.Height = fitSize(req.Height)
	}

	thumbName := fmt.Sprintf("%s_%dx%d.jpg", ThumbnailHash(path.Join(req.ProviderID, req.Path)), req.Width, req.Height)

	_, err := t.thumbnailStorage.Stat(context.TODO(), path.Join(t.path, thumbName))
	if err == nil {
		// thumbnail exists
		resp.ProviderID = t.fileProviderId
		resp.Path = path.Join(t.path, thumbName)
		return
	}
	if !errors.Is(err, os.ErrNotExist) {
		t.log.Error("error while accessing thumbnail storage", "error", err)
		resp.Error = "error while accessing thumbnail storage" + err.Error()
		return
	}

	// thumbnail needs to be created
	// limit concurrency to avoid excessive memory usage
	if !t.limiter.Begin() {
		resp.Error = "operation cancelled"
		return
	}
	defer t.limiter.End()

	fs := fileprovider.NewFileProviderClient(req.ProviderID, t.nc, t.logging)

	file, err := fs.OpenFile(context.TODO(), req.Path, os.O_RDONLY, 0)
	if err != nil {
		t.log.Error("error while opening source file for thumbnail creation", "provider", req.ProviderID, "path", req.Path, "error", err)
		resp.Error = "error while opening source file for thumbnail creation: " + err.Error()
		return
	}
	defer file.Close()

	start := time.Now()
	imageConfig, format, err := image.DecodeConfig(file)
	if err != nil {
		t.log.Error("error while reading image metadata", "provider", req.ProviderID, "path", req.Path, "error", err)
		resp.Error = "error while reading image metadata" + err.Error()
		return
	}
	elapsed := time.Since(start)
	t.log.Debug("decoded image metadata", "format", format, "width", imageConfig.Width, "height", imageConfig.Height, "time", elapsed)

	if imageConfig.Width > MaxImageWidth || imageConfig.Height > MaxImageHeight {
		t.log.Error("source image too large for thumbnail creation", "provider", req.ProviderID, "path", req.Path, "width", imageConfig.Width, "height", imageConfig.Height)
		resp.Error = "source image too large for thumbnail creation"
		return
	}

	_, err = file.Seek(0, io.SeekStart)
	if err != nil {
		t.log.Error("error while accessing source file", "provider", req.ProviderID, "path", req.Path, "error", err)
		resp.Error = "error while accessing source file" + err.Error()
		return
	}

	start = time.Now()
	// use large buffer size for improved performance (default is only 4096 bytes)
	reader := bufio.NewReaderSize(file, 512*1024)
	sourceImage, err := imaging.Decode(reader, imaging.AutoOrientation(true))
	if err != nil {
		t.log.Error("error while decoding source image", "provider", req.ProviderID, "path", req.Path, "error", err)
		resp.Error = "error while decoding source image" + err.Error()
		return
	}
	elapsed = time.Since(start)
	t.log.Debug("decoded image", "time", elapsed)

	start = time.Now()
	dstImage := imaging.Fit(sourceImage, req.Width, req.Height, imaging.Lanczos)
	elapsed = time.Since(start)
	t.log.Debug("scaled image", "width", dstImage.Bounds().Size().X, "height", dstImage.Bounds().Size().Y, "time", elapsed)

	tmpFilePath := path.Join(t.path, tmpFolderName, randomFileName())
	thumbPath := path.Join(t.path, thumbName)
	dstFile, err := t.thumbnailStorage.OpenFile(context.TODO(), tmpFilePath, os.O_CREATE|os.O_RDWR|os.O_TRUNC, 0666)
	if err != nil {
		t.log.Error("error while opening thumbnail destination for writing", "error", err)
		resp.Error = "error while opening thumbnail destination for writing" + err.Error()
		return
	}

	start = time.Now()
	err = jpeg.Encode(dstFile, dstImage, &jpeg.Options{
		Quality: t.options.JpegQuality,
	})
	if err != nil {
		defer dstFile.Close()
		t.log.Error("error while writing thumbnail", "error", err)
		resp.Error = "error while writing thumbnail" + err.Error()
		return
	}
	elapsed = time.Since(start)
	t.log.Debug("encoded thumbnail", "time", elapsed)
	dstFile.Close()

	err = t.thumbnailStorage.Rename(context.TODO(), tmpFilePath, thumbPath)
	if err != nil {
		t.log.Error("error while moving thumbnail to destination", "error", err)
		resp.Error = "error while moving thumbnail to destination" + err.Error()
		return
	}

	resp.ProviderID = t.fileProviderId
	resp.Path = thumbPath
	return
}

func fitSize(s int) int {
	l := ThumbnailSizes[0]
	for _, t := range ThumbnailSizes[1:] {
		if s < t {
			return l
		}
		l = t
	}
	return l
}

func randomFileName() string {
	return strconv.Itoa(int(rand.Uint32()))
}
