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
	"sync"
	"time"

	"github.com/disintegration/imaging"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/fx"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/tracing"
	"umbasa.net/seraph/util"

	_ "image/gif"
	"image/jpeg"
	_ "image/png"
)

const ThumbnailRequestTopic = "seraph.thumbnail.request"

// default maximum acceptable source image size for thumbnail creation, used
// when not overridden via Options.MaxImageWidth / Options.MaxImageHeight.
//
// This bounds the memory used to decode the source image, so it is
// configurable rather than unlimited. The default is set comfortably above
// current flagship phone resolutions, including Samsung's 200 MP mode
// (16320x12240), so recent high-resolution photos are not rejected.
const DefaultMaxImageWidth = 20000
const DefaultMaxImageHeight = 20000

// error classes returned in ThumbnailResponse.ErrorClass, allowing callers to
// distinguish the reason a thumbnail could not be created.
const (
	// ErrorClassTooLarge indicates the source image exceeds the configured
	// maximum thumbnailable dimensions.
	ErrorClassTooLarge = "TooLarge"
	// ErrorClassUnsupportedFormat indicates the source file is not a
	// recognized/decodable image format.
	ErrorClassUnsupportedFormat = "UnsupportedFormat"
	// ErrorClassCorrupt indicates the source file is a recognized image
	// format but could not be decoded.
	ErrorClassCorrupt = "Corrupt"
)

// common thumbnail sizes in pixels
var ThumbnailSizes = []int{128, 256, 512, 1024}

const DefaultThumbnailSize = 256

// content type for thumbnails
const ContentType = "image/jpeg"

// name of temporary folder where thumb files are put during creation
const tmpFolderName = "_tmp"

const bufferSize = 512 * 1024

type Params struct {
	fx.In

	Nc      *nats.Conn
	Js      jetstream.JetStream `optional:"true"`
	Logger  *logging.Logger
	Tracing *tracing.Tracing
	Options *Options `optional:"true"`
}

type Options struct {
	JpegQuality int
	Parallel    int
	// MaxImageWidth and MaxImageHeight bound the source image dimensions
	// accepted for thumbnail creation. Zero means "use the default"
	// (DefaultMaxImageWidth / DefaultMaxImageHeight).
	MaxImageWidth  int
	MaxImageHeight int
}

type Result struct {
	fx.Out

	Thumbnailer *Thumbnailer
}

type Thumbnailer struct {
	options          Options
	logging          *logging.Logger
	log              *slog.Logger
	tracer           trace.Tracer
	nc               *nats.Conn
	js               jetstream.JetStream
	fileProviderId   string
	path             string
	thumbnailStorage fileprovider.Client

	mu           sync.Mutex
	sub          *nats.Subscription
	requestChan  chan *nats.Msg
	limiter      util.Limiter
	invalidation *invalidationConsumer
	ctx          context.Context
	cancel       context.CancelFunc
	wg           sync.WaitGroup
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
	if options.MaxImageWidth == 0 {
		options.MaxImageWidth = DefaultMaxImageWidth
	}
	if options.MaxImageHeight == 0 {
		options.MaxImageHeight = DefaultMaxImageHeight
	}

	tracer := p.Tracing.TracerProvider.Tracer("thumbnailer")

	return Result{
		Thumbnailer: &Thumbnailer{
			options:          *options,
			logging:          p.Logger,
			log:              p.Logger.GetLogger("thumbnailer"),
			tracer:           tracer,
			nc:               p.Nc,
			js:               p.Js,
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

	limiter := util.NewLimiter(t.options.Parallel)
	requestChan := make(chan *nats.Msg, nats.DefaultSubPendingMsgsLimit)

	sub, err := t.nc.ChanQueueSubscribe(ThumbnailRequestTopic, ThumbnailRequestTopic, requestChan)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithCancel(context.Background())

	t.mu.Lock()
	t.limiter = limiter
	t.requestChan = requestChan
	t.sub = sub
	t.ctx = ctx
	t.cancel = cancel
	t.mu.Unlock()

	t.wg.Add(1)
	go t.messageLoop(ctx, requestChan, limiter)

	// the durable file-change consumer runs alongside the preview request
	// loop, sharing the same ctx/wg shutdown so Stop() joins both.
	invalidation, err := t.startInvalidationConsumer(ctx)
	if err != nil {
		t.log.Error("failed to start file-change invalidation consumer; thumbnails will not be cleaned up on file changes", "error", err)
	} else {
		t.mu.Lock()
		t.invalidation = invalidation
		t.mu.Unlock()
	}

	return nil
}

func (t *Thumbnailer) Stop() error {
	t.mu.Lock()
	sub := t.sub
	requestChan := t.requestChan
	cancel := t.cancel
	invalidation := t.invalidation
	t.sub = nil
	t.requestChan = nil
	t.limiter = nil
	t.invalidation = nil
	t.ctx = nil
	t.cancel = nil
	t.mu.Unlock()

	var err error
	if sub != nil {
		err = sub.Unsubscribe()
	}
	if requestChan != nil {
		close(requestChan)
	}
	if invalidation != nil {
		invalidation.stop()
	}
	if cancel != nil {
		cancel()
	}

	// waits for messageLoop, any in-flight handleMessage goroutines, and the
	// invalidation consumer's loop/handlers, which subsumes the limiters'
	// own accounting of running work
	t.wg.Wait()

	return err
}

func (t *Thumbnailer) messageLoop(ctx context.Context, requestChan chan *nats.Msg, limiter util.Limiter) {
	defer t.wg.Done()

	for {
		msg, ok := <-requestChan
		if !ok {
			return
		}

		t.wg.Add(1)
		go t.handleMessage(ctx, limiter, msg)
	}
}

func (t *Thumbnailer) handleMessage(ctx context.Context, limiter util.Limiter, msg *nats.Msg) {
	defer t.wg.Done()

	ctx = messaging.ExtractTraceContext(ctx, msg)

	req := ThumbnailRequest{}
	req.Unmarshal(msg.Data)

	resp := t.handleRequest(ctx, limiter, req)

	data, _ := resp.Marshal()

	msg.Respond(data)
}

func (t *Thumbnailer) handleRequest(ctx context.Context, limiter util.Limiter, req ThumbnailRequest) (resp ThumbnailResponse) {
	ctx, span := t.tracer.Start(ctx, "handleRequest")
	defer span.End()

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
	req.Width = fitSize(req.Width)
	req.Height = fitSize(req.Height)

	thumbName := fmt.Sprintf("%s_%dx%d.jpg", ThumbnailHash(path.Join(req.ProviderID, req.Path)), req.Width, req.Height)

	_, err := t.thumbnailStorage.Stat(ctx, path.Join(t.path, thumbName))
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
	if !limiter.Begin(ctx) {
		resp.Error = "operation cancelled"
		return
	}
	defer limiter.End()

	ctx, span = t.tracer.Start(ctx, "createThumbnail")
	defer span.End()

	fs := fileprovider.NewFileProviderClient(req.ProviderID, t.nc, t.logging)
	defer fs.Close()

	file, err := fs.OpenFile(ctx, req.Path, os.O_RDONLY, 0)
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
		if errors.Is(err, image.ErrFormat) {
			resp.Error = "source file is not a supported image format: " + err.Error()
			resp.ErrorClass = ErrorClassUnsupportedFormat
		} else {
			resp.Error = "source image is corrupt or unreadable: " + err.Error()
			resp.ErrorClass = ErrorClassCorrupt
		}
		return
	}
	elapsed := time.Since(start)
	t.log.Debug("decoded image metadata", "format", format, "width", imageConfig.Width, "height", imageConfig.Height, "time", elapsed)

	maxWidth := t.options.MaxImageWidth
	maxHeight := t.options.MaxImageHeight
	if imageConfig.Width > maxWidth || imageConfig.Height > maxHeight {
		t.log.Error("source image too large for thumbnail creation", "provider", req.ProviderID, "path", req.Path, "width", imageConfig.Width, "height", imageConfig.Height, "maxWidth", maxWidth, "maxHeight", maxHeight)
		resp.Error = fmt.Sprintf("source image (%dx%d) exceeds the maximum thumbnailable size (%dx%d)", imageConfig.Width, imageConfig.Height, maxWidth, maxHeight)
		resp.ErrorClass = ErrorClassTooLarge
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
	reader := bufio.NewReaderSize(file, bufferSize)
	sourceImage, err := imaging.Decode(reader, imaging.AutoOrientation(true))
	if err != nil {
		t.log.Error("error while decoding source image", "provider", req.ProviderID, "path", req.Path, "error", err)
		if errors.Is(err, image.ErrFormat) {
			resp.Error = "source file is not a supported image format: " + err.Error()
			resp.ErrorClass = ErrorClassUnsupportedFormat
		} else {
			resp.Error = "source image is corrupt or unreadable: " + err.Error()
			resp.ErrorClass = ErrorClassCorrupt
		}
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
	dstFile, err := t.thumbnailStorage.OpenFile(ctx, tmpFilePath, os.O_CREATE|os.O_RDWR|os.O_TRUNC, 0666)
	if err != nil {
		t.log.Error("error while opening thumbnail destination for writing", "error", err)
		resp.Error = "error while opening thumbnail destination for writing" + err.Error()
		return
	}

	writer := bufio.NewWriterSize(dstFile, bufferSize)

	start = time.Now()
	err = jpeg.Encode(writer, dstImage, &jpeg.Options{
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
	writer.Flush()
	dstFile.Close()

	err = t.thumbnailStorage.Rename(ctx, tmpFilePath, thumbPath)
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
	for _, t := range ThumbnailSizes {
		if t >= s {
			return t
		}
	}
	return ThumbnailSizes[len(ThumbnailSizes)-1]
}

func randomFileName() string {
	return strconv.Itoa(int(rand.Uint32()))
}
