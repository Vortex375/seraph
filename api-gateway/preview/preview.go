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

package preview

import (
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/nats-io/nats.go"
	"go.uber.org/fx"
	"umbasa.net/seraph/api-gateway/auth"
	"umbasa.net/seraph/api-gateway/gateway-handler"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/shares/shares"
	"umbasa.net/seraph/thumbnailer/thumbnailer"
	"umbasa.net/seraph/util"
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
			authHandler: p.Auth.AuthMiddleware(false, ""),
		},
	}
}

func (h *previewHandler) Setup(app *gin.Engine, apiGroup *gin.RouterGroup) {
	app.GET("preview", func(ctx *gin.Context) {
		var err error
		parameterP := ctx.Query("p")
		parameterS := ctx.Query("s")

		if parameterP != "" && parameterS != "" {
			h.log.Error("both 'p' and 's' specified - only one can be used")
			ctx.AbortWithStatus(http.StatusBadRequest)
			return
		}

		if parameterP == "" && parameterS == "" {
			h.log.Error("missing 'p' or 's' parameter")
			ctx.AbortWithStatus(http.StatusBadRequest)
			return
		}

		var providerId, path string
		if parameterS != "" {
			shareId, sharePath := getProviderAndPath(parameterS)
			resolveReq := shares.ShareResolveRequest{
				ShareId: shareId,
				Path:    sharePath,
			}
			resolveRes := shares.ShareResolveResponse{}
			err = messaging.Request(ctx.Request.Context(), h.nc, shares.ShareResolveTopic, messaging.Json(&resolveReq), messaging.Json(&resolveRes))
			if err != nil {
				h.log.Error("While retrieving preview: error while resolving share", "error", err)
				ctx.AbortWithStatus(http.StatusInternalServerError)
				return
			}
			if resolveRes.Error != "" {
				h.log.Error("While retrieving preview: error while resolving share", "error", resolveRes.Error)
				ctx.AbortWithStatus(http.StatusInternalServerError)
				return
			}
			if resolveRes.ProviderId == "" {
				ctx.AbortWithStatus(http.StatusNotFound)
				return
			}

			providerId = resolveRes.ProviderId
			path = resolveRes.Path
		} else {
			if !h.authHandler(ctx) {
				return
			}
			providerId, path = getProviderAndPath(parameterP)
			if providerId == "" || path == "" {
				h.log.Error("path must include providerId and path resp. filename")
				ctx.AbortWithStatus(http.StatusBadRequest)
				return
			}
		}

		var width, height int
		if ws := ctx.Query("w"); ws != "" {
			width, err = strconv.Atoi(ws)
			if err != nil {
				h.log.Error("invalid 'w' parameter: " + ws)
				ctx.AbortWithStatus(http.StatusBadRequest)
				return
			}
		}
		if hs := ctx.Query("h"); hs != "" {
			height, err = strconv.Atoi(hs)
			if err != nil {
				h.log.Error("invalid 'h' parameter: " + hs)
				ctx.AbortWithStatus(http.StatusBadRequest)
				return
			}
		}
		exact := ctx.Query("exact") != ""

		req := thumbnailer.ThumbnailRequest{
			ProviderID: providerId,
			Path:       path,
			Width:      width,
			Height:     height,
			Exact:      exact,
		}
		resp := thumbnailer.ThumbnailResponse{}
		err = messaging.Request(ctx.Request.Context(), h.nc, thumbnailer.ThumbnailRequestTopic, &req, &resp)

		if err != nil {
			h.log.Error("error retrieving thumbnail response", "error", err)
			ctx.AbortWithStatus(http.StatusInternalServerError)
			return
		}

		if resp.Error != "" {
			h.log.Error("error retrieving thumbnail response", "error", resp.Error)
			ctx.AbortWithStatus(http.StatusInternalServerError)
			return
		}

		client := fileprovider.NewFileProviderClient(resp.ProviderID, h.nc, h.logger)
		defer client.Close()
		file, err := client.OpenFile(ctx.Request.Context(), resp.Path, os.O_RDONLY, 0)
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

		fastReader := &util.FastReader{
			Reader: file,
		}
		ctx.DataFromReader(http.StatusOK, stat.Size(), thumbnailer.ContentType, fastReader, map[string]string{
			"Cache-Control": "max-age=604800",
		})
	})
}

func getProviderAndPath(p string) (string, string) {
	split := strings.SplitN(strings.TrimPrefix(p, "/"), "/", 2)

	if len(split) == 1 {
		return split[0], ""
	}

	if len(split) == 2 {
		return split[0], split[1]
	}

	return "", ""
}
