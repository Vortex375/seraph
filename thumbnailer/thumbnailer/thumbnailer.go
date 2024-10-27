package thumbnailer

import (
	"context"
	"errors"
	"fmt"
	"image"
	"io"
	"log/slog"
	"math/rand"
	"os"
	"path"
	"strconv"
	"time"

	"github.com/nats-io/nats.go"
	"go.uber.org/fx"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"

	_ "image/gif"
	"image/jpeg"
	_ "image/png"

	"golang.org/x/image/draw"
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

	Nc     *nats.Conn
	Logger *logging.Logger
}

type Result struct {
	fx.Out

	Thumbnailer *Thumbnailer
}

type Thumbnailer struct {
	logging          *logging.Logger
	log              *slog.Logger
	nc               *nats.Conn
	fileProviderId   string
	path             string
	thumbnailStorage fileprovider.Client
	sub              *nats.Subscription
}

func NewThumbnailer(p Params, fileProviderId string, path string, thumbnailStorage fileprovider.Client) (Result, error) {
	return Result{
		Thumbnailer: &Thumbnailer{
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

	sub, err := t.nc.QueueSubscribe(ThumbnailRequestTopic, ThumbnailRequestTopic, func(msg *nats.Msg) {
		req := ThumbnailRequest{}
		req.Unmarshal(msg.Data)

		resp := t.handleRequest(req)

		data, _ := resp.Marshal()

		msg.Respond(data)
	})

	if err != nil {
		return err
	}

	t.sub = sub
	return nil
}

func (t *Thumbnailer) Stop() error {
	var err error
	if t.sub != nil {
		err = t.sub.Unsubscribe()
		t.sub = nil
	}
	return err
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
	sourceImage, _, err := image.Decode(file)
	if err != nil {
		t.log.Error("error while decoding source image", "provider", req.ProviderID, "path", req.Path, "error", err)
		resp.Error = "error while decoding source image" + err.Error()
		return
	}
	elapsed = time.Since(start)
	t.log.Debug("decoded image", "time", elapsed)

	start = time.Now()
	dstWidth, dstHeight := calculateThumbnailSize(imageConfig.Width, imageConfig.Height, req.Width, req.Height)
	dstImage := image.NewRGBA(image.Rect(0, 0, dstWidth, dstHeight))
	draw.ApproxBiLinear.Scale(dstImage, dstImage.Bounds(), sourceImage, sourceImage.Bounds(), draw.Over, nil)
	elapsed = time.Since(start)
	t.log.Debug("scaled image", "width", dstWidth, "height", dstHeight, "time", elapsed)

	tmpFilePath := path.Join(t.path, tmpFolderName, randomFileName())
	thumbPath := path.Join(t.path, thumbName)
	dstFile, err := t.thumbnailStorage.OpenFile(context.TODO(), tmpFilePath, os.O_CREATE|os.O_RDWR|os.O_TRUNC, 0666)
	if err != nil {
		t.log.Error("error while opening thumbnail destination for writing", "error", err)
		resp.Error = "error while opening thumbnail destination for writing" + err.Error()
		return
	}

	start = time.Now()
	//TODO: jpeg options!?
	err = jpeg.Encode(dstFile, dstImage, nil)
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

func calculateThumbnailSize(srcW int, srcH int, dstW int, dstH int) (resW int, resH int) {
	if srcW < dstW && srcH < dstH {
		// source image is smaller than destination -> we don't scale the image up
		return srcW, srcH
	}

	aspect := float64(srcW) / float64(srcH)

	srcRect := image.Rect(0, 0, srcW, srcH)
	dstRect := image.Rect(0, 0, dstW, dstH)
	intersect := srcRect.Intersect(dstRect)

	if srcW > intersect.Size().X {
		resW = intersect.Size().X
		resH = int(float64(resW) / aspect)
	} else {
		resH = intersect.Size().Y
		resW = int(float64(resH) * aspect)
	}

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
