package preview

import (
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/nats-io/nats.go"
	"go.uber.org/fx"
	"umbasa.net/seraph/api-gateway/auth"
	"umbasa.net/seraph/api-gateway/gateway-handler"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/thumbnailer/thumbnailer"
)

var Module = fx.Module("preview",
	fx.Provide(
		New,
	),
)

type Params struct {
	fx.In

	Log  *logging.Logger
	Nc   *nats.Conn
	Auth auth.Auth
}

type Result struct {
	fx.Out

	Handler gateway.GatewayHandler `group:"gatewayhandlers"`
}

type previewHandler struct {
	logger      *logging.Logger
	log         *slog.Logger
	nc          *nats.Conn
	authHandler func(*gin.Context) bool
}

func New(p Params) Result {
	return Result{
		Handler: &previewHandler{
			logger:      p.Log,
			log:         p.Log.GetLogger("preview"),
			nc:          p.Nc,
			authHandler: p.Auth.AuthMiddleware(),
		},
	}
}

func (h *previewHandler) Setup(app *gin.Engine, apiGroup *gin.RouterGroup) {
	app.GET("preview", func(ctx *gin.Context) {
		path := ctx.Query("p")
		share := ctx.Query("s")

		if path != "" && share != "" {
			h.log.Error("both 'p' and 's' specified - only one can be used")
			ctx.AbortWithStatus(http.StatusBadRequest)
			return
		}

		if path == "" && share == "" {
			h.log.Error("missing 'p' or 's' parameter")
			ctx.AbortWithStatus(http.StatusBadRequest)
			return
		}

		if share != "" {
			ctx.AbortWithStatus(http.StatusNotImplemented)
			return
		} else {
			if !h.authHandler(ctx) {
				return
			}
		}

		var width, height int
		if ws := ctx.Query("w"); ws != "" {
			var err error
			width, err = strconv.Atoi(ws)
			if err != nil {
				h.log.Error("invalid 'w' parameter: " + ws)
				ctx.AbortWithStatus(http.StatusBadRequest)
				return
			}
		}
		if hs := ctx.Query("h"); hs != "" {
			var err error
			height, err = strconv.Atoi(hs)
			if err != nil {
				h.log.Error("invalid 'h' parameter: " + hs)
				ctx.AbortWithStatus(http.StatusBadRequest)
				return
			}
		}
		exact := ctx.Query("exact") != ""

		providerId, path := getProviderAndPath(path)

		if providerId == "" || path == "" {
			h.log.Error("path must include providerId and path resp. filename")
			ctx.AbortWithStatus(http.StatusBadRequest)
			return
		}

		req := thumbnailer.ThumbnailRequest{
			ProviderID: providerId,
			Path:       path,
			Width:      width,
			Height:     height,
			Exact:      exact,
		}
		reqData, _ := req.Marshal()
		respMsg, err := h.nc.Request(thumbnailer.ThumbnailRequestTopic, reqData, 30*time.Second)
		if err != nil {
			h.log.Error("error retrieving thumbnail response", "error", err)
			ctx.AbortWithStatus(http.StatusInternalServerError)
			return
		}

		resp := thumbnailer.ThumbnailResponse{}
		resp.Unmarshal(respMsg.Data)

		if resp.Error != "" {
			h.log.Error("error retrieving thumbnail response", "error", resp.Error)
			ctx.AbortWithStatus(http.StatusInternalServerError)
			return
		}

		client := fileprovider.NewFileProviderClient(resp.ProviderID, h.nc, h.logger)
		file, err := client.OpenFile(ctx, resp.Path, os.O_RDONLY, 0)
		if err != nil {
			h.log.Error("error opening thumbnail", "error", err)
			ctx.AbortWithStatus(http.StatusInternalServerError)
			return
		}
		defer file.Close()

		stat, err := file.Stat()
		if err != nil {
			h.log.Error("error accessing thumbnail", "error", err)
			ctx.AbortWithStatus(http.StatusInternalServerError)
			return
		}

		ctx.DataFromReader(http.StatusOK, stat.Size(), thumbnailer.ContentType, file, map[string]string{
			"Cache-Control": "max-age=604800",
		})
	})
}

func getProviderAndPath(p string) (string, string) {
	split := strings.SplitN(strings.TrimPrefix(p, "/"), "/", 2)

	if len(split) != 2 {
		return "", ""
	}

	return split[0], split[1]
}
