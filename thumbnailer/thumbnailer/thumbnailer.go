package thumbnailer

import (
	"context"
	"errors"
	"fmt"
	"image"
	"io"
	"log/slog"
	"os"
	"path"
	"strings"

	"github.com/gofiber/fiber/v2/log"
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

	provider, sourcePath := getProviderAndPath(req.Path)
	if provider == "" {
		resp.Error = "invalid path: first path segment must be file provider id"
		return
	}

	thumbName := fmt.Sprintf("%s_%dx%d.jpg", ThumbnailHash(req.Path), req.Width, req.Height)

	_, err := t.thumbnailStorage.Stat(context.TODO(), path.Join(t.path, thumbName))
	if err == nil {
		// thumbnail exists
		resp.Path = path.Join(t.fileProviderId, t.path, thumbName)
		return
	}
	if !errors.Is(err, os.ErrNotExist) {
		log.Error("error while accessing thumbnail storage", "error", err)
		resp.Error = "error while accessing thumbnail storage" + err.Error()
		return
	}

	// thumbnail needs to be created

	fs := fileprovider.NewFileProviderClient(provider, t.nc, t.logging)

	file, err := fs.OpenFile(context.TODO(), sourcePath, os.O_RDONLY, 0)
	if err != nil {
		log.Error("error while opening source file for thumbnail creation", "path", req.Path, "error", err)
		resp.Error = "error while opening source file for thumbnail creation: " + err.Error()
		return
	}
	defer file.Close()

	imageConfig, format, err := image.DecodeConfig(file)
	if err != nil {
		log.Error("error while reading image metadata", "path", req.Path, "error", err)
		resp.Error = "error while reading image metadata" + err.Error()
		return
	}
	log.Debug("decoded image metadata", "format", format, "width", imageConfig.Width, "height", imageConfig.Height)

	if imageConfig.Width > MaxImageWidth || imageConfig.Height > MaxImageHeight {
		log.Error("source image too large for thumbnail creation", "path", req.Path, "width", imageConfig.Width, "height", imageConfig.Height)
		resp.Error = "source image too large for thumbnail creation"
		return
	}

	_, err = file.Seek(0, io.SeekStart)
	if err != nil {
		log.Error("error while accessing source file", "path", req.Path, "error", err)
		resp.Error = "error while accessing source file" + err.Error()
		return
	}

	sourceImage, _, err := image.Decode(file)
	if err != nil {
		log.Error("error while decoding source image", "path", req.Path, "error", err)
		resp.Error = "error while decoding source image" + err.Error()
		return
	}

	dstWidth, dstHeight := calculateThumbnailSize(imageConfig.Width, imageConfig.Height, req.Width, req.Height)
	dstImage := image.NewRGBA(image.Rect(0, 0, dstWidth, dstHeight))
	draw.ApproxBiLinear.Scale(dstImage, dstImage.Bounds(), sourceImage, sourceImage.Bounds(), draw.Over, nil)

	dstFile, err := t.thumbnailStorage.OpenFile(context.TODO(), path.Join(t.path, thumbName), os.O_CREATE|os.O_RDWR|os.O_TRUNC, 0666)
	if err != nil {
		log.Error("error while opening thumbnail destination for writing", "error", err)
		resp.Error = "error while opening thumbnail destination for writing" + err.Error()
		return
	}
	defer dstFile.Close()
	//TODO: jpeg options!?
	jpeg.Encode(dstFile, dstImage, nil)

	resp.Path = path.Join(t.fileProviderId, t.path, thumbName)
	return
}

func getProviderAndPath(p string) (string, string) {
	split := strings.SplitN(strings.TrimPrefix(p, "/"), "/", 2)

	if len(split) != 2 {
		return "", ""
	}

	return split[0], split[1]
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
