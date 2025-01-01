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
	logger     *logging.Logger
	nc         *nats.Conn
	auth       auth.Auth
	clients    *sync.Map
	lockSystem webdav.LockSystem
}

func New(p Params) Result {
	server := &webDavServer{p.Log, p.Nc, p.Auth, &sync.Map{}, webdav.NewMemLS()}
	return Result{Server: server, Handler: server}
}

func (server *webDavServer) Setup(app *gin.Engine, apiGroup *gin.RouterGroup) {
	// Gin's router doesn't handle WebDAV methods like PROPFIND, so we must register a global middleware here
	passwordAuth := server.auth.AuthMiddleware(true, "Access to WebDAV")
	handler := &webdav.Handler{
		Prefix:     PathPrefix,
		FileSystem: &delegatingFs{server, *server.logger.GetLogger("webdav.fs")},
		LockSystem: server.lockSystem,
		Logger:     makeLogger(server.logger),
	}
	app.Use(scoped(PathPrefix, false, func(ctx *gin.Context) { passwordAuth(ctx) }))
	app.Use(scoped(PathPrefix, true, func(ctx *gin.Context) {
		handler.ServeHTTP(&fastResponseWriter{ctx.Writer}, ctx.Request)
		ctx.Abort()
	}))
	app.Any("/dav/*path", func(*gin.Context) {
		// dummy method to prevent GIN returning 404
	})
}

func (server *webDavServer) getClient(providerId string) fileprovider.Client {
	client, ok := server.clients.Load(providerId)
	if !ok {
		newClient := fileprovider.NewFileProviderClient(providerId, server.nc, server.logger)
		existingClient, loaded := server.clients.LoadOrStore(providerId, newClient)
		if loaded {
			newClient.Close()
			client = existingClient
		} else {
			client = newClient
		}
	}
	return client.(fileprovider.Client)
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
