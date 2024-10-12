// Copyright © 2024 Benjamin Schmitz

// This file is part of Seraph.

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

package webdav

import (
	"log/slog"
	"net/http"
	"strings"
	"sync"

	"github.com/gin-gonic/gin"
	"github.com/nats-io/nats.go"
	"go.uber.org/fx"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/api-gateway/auth"
	"umbasa.net/seraph/api-gateway/gateway-handler"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"
)

const PathPrefix = "/dav"

var Module = fx.Module("webdav",
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

	Server  WebDavServer
	Handler gateway.GatewayHandler `group:"gatewayhandlers"`
}

type WebDavServer interface {
	//TODO
}

type webDavServer struct {
	logger   *logging.Logger
	nc       *nats.Conn
	auth     auth.Auth
	handlers *sync.Map
}

func New(p Params) Result {
	server := &webDavServer{p.Log, p.Nc, p.Auth, &sync.Map{}}
	return Result{Server: server, Handler: server}
}

func (server *webDavServer) Setup(app *gin.Engine, apiGroup *gin.RouterGroup) {

	// Gin's router doesn't handle WebDAV methods like PROPFIND, so we must register a global middleware here
	app.Use(scoped(PathPrefix, false, server.auth.PasswordAuthMiddleware("Access to WebDAV")))
	app.Use(scoped(PathPrefix, true, func(ctx *gin.Context) {
		providerId := getProviderId(ctx)
		if providerId == "" {
			ctx.AbortWithStatus(http.StatusNotFound)
			return
		}
		handler := server.getHandler(providerId)
		handler.ServeHTTP(&fastResponseWriter{ctx.Writer}, ctx.Request)
		ctx.Abort()
	}))

	app.Any("/dav/:providerId/*path", func(*gin.Context) {
		// dummy method to prevent GIN returning 404
	})
}

func getProviderId(ctx *gin.Context) string {
	// Param() does not work when the request method is PROPFIND or some other non-standard HTTP method
	providerId := ctx.Param("providerId")
	if providerId == "" {
		split := strings.Split(ctx.Request.URL.Path, "/")
		if strings.HasPrefix(ctx.Request.URL.Path, "/") && len(split) > 2 {
			return split[2]
		} else if len(split) > 1 {
			return split[1]
		}
	}
	return providerId
}

func (server *webDavServer) getHandler(providerId string) webdav.Handler {
	handler, ok := server.handlers.Load(providerId)

	if !ok {
		client := fileprovider.NewFileProviderClient(providerId, server.nc, server.logger)

		handler = webdav.Handler{
			Prefix:     PathPrefix + "/" + providerId,
			FileSystem: client,
			LockSystem: webdav.NewMemLS(),
			Logger:     makeLogger(server.logger),
		}

		handler, _ = server.handlers.LoadOrStore(providerId, handler)
	}

	return handler.(webdav.Handler)
}

func makeLogger(logger *logging.Logger) func(*http.Request, error) {
	log := logger.GetLogger("webdav")
	return func(r *http.Request, err error) {
		if err != nil {
			log.Error(err.Error())
		} else {
			log.Debug("handling request", slog.Group("request", "method", r.Method, "path", r.URL.Path, "headers", r.Header))
		}
	}
}

func scoped(prefix string, abort bool, handler func(*gin.Context)) func(*gin.Context) {
	return func(ctx *gin.Context) {
		if strings.HasPrefix(ctx.Request.URL.Path, prefix) {
			handler(ctx)
			if abort {
				ctx.Abort()
			}
		}
	}
}
