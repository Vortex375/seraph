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

package download

import (
	"archive/zip"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path"
	"strings"

	"github.com/gin-gonic/gin"
	"go.uber.org/fx"
	"umbasa.net/seraph/api-gateway/auth"
	"umbasa.net/seraph/api-gateway/gateway-handler"
	"umbasa.net/seraph/api-gateway/webdav"
	"umbasa.net/seraph/logging"
)

var Module = fx.Module("download",
	fx.Provide(
		New,
	),
)

type Params struct {
	fx.In

	Log    *logging.Logger
	WebDav webdav.WebDavServer
	Auth   auth.Auth
}

type Result struct {
	fx.Out

	Handler gateway.GatewayHandler `group:"gatewayhandlers"`
}

type downloadHandler struct {
	logger *logging.Logger
	log    *slog.Logger
	auth   auth.Auth
	webdav webdav.WebDavServer
}

func New(p Params) Result {
	return Result{
		Handler: &downloadHandler{
			logger: p.Log,
			log:    p.Log.GetLogger("download"),
			auth:   p.Auth,
			webdav: p.WebDav,
		},
	}
}

func (h *downloadHandler) Setup(app *gin.Engine, apiGroup *gin.RouterGroup, publicApiGroup *gin.RouterGroup) {
	app.GET("download/*path",
		func(ctx *gin.Context) {
			requestPath := ctx.Param("path")
			if !strings.HasPrefix(requestPath, "/s/") {
				h.auth.AuthMiddleware(false, "")(ctx)
			}
		},
		webdav.CacheMiddleware(),
		func(ctx *gin.Context) {
			requestPath := ctx.Param("path")

			if requestPath == "" {
				ctx.AbortWithStatus(http.StatusNotFound)
				return
			}

			fileSystem := h.webdav.FileSystem()

			fileInfo, err := fileSystem.Stat(ctx.Request.Context(), requestPath)
			if err != nil {
				ctx.AbortWithError(http.StatusInternalServerError, err)
				return
			}

			ctx.Status(http.StatusOK)
			ctx.Header("Content-Type", "application/zip")
			ctx.Header("Content-Disposition", fmt.Sprintf("attachment; filename=%s.zip", path.Base(requestPath)))

			pr, pw := io.Pipe()
			zipWriter := zip.NewWriter(pw)

			go func() {
				if fileInfo.IsDir() {
					err = zipWriter.AddFS(webdav.AsFs(ctx.Request.Context(), fileSystem, requestPath))
					if err != nil {
						pw.CloseWithError(err)
						return
					}
				} else {
					header, err := zip.FileInfoHeader(fileInfo)
					if err != nil {
						pw.CloseWithError(err)
						return
					}
					header.Method = zip.Deflate
					w, err := zipWriter.CreateHeader(header)
					if err != nil {
						pw.CloseWithError(err)
						return
					}
					file, err := fileSystem.OpenFile(ctx.Request.Context(), requestPath, os.O_RDONLY, 0)
					if err != nil {
						pw.CloseWithError(err)
						return
					}
					defer file.Close()

					_, err = io.Copy(w, file)
					if err != nil {
						pw.CloseWithError(err)
						return
					}
				}
				zipWriter.Close()
				pw.Close()
			}()

			_, err = io.Copy(ctx.Writer, pr)
			if err != nil {
				h.log.Error("failed to create zip archive for download", "error", err, "path", requestPath)
			}
		})
}
