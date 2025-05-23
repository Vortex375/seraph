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
	"context"
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
	"umbasa.net/seraph/shares/shares"
	"umbasa.net/seraph/spaces/spaces"
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
	FileSystem() webdav.FileSystem
}

type webDavServer struct {
	logger     *logging.Logger
	nc         *nats.Conn
	auth       auth.Auth
	clients    *sync.Map
	fs         *delegatingFs
	lockSystem webdav.LockSystem
}

// key for request-scoped cache for delegatingFs.resolveSpace()
type spaceResolveCacheKey struct{}

// key for request-scoped cache for delegatingFs.resolveShare()
type shareResolveCacheKey struct{}

func New(p Params) Result {
	server := &webDavServer{
		logger:     p.Log,
		nc:         p.Nc,
		auth:       p.Auth,
		clients:    &sync.Map{},
		lockSystem: webdav.NewMemLS(),
	}
	fs := &delegatingFs{server, *server.logger.GetLogger("webdav.fs")}
	server.fs = fs
	return Result{Server: server, Handler: server}
}

func (server *webDavServer) Setup(app *gin.Engine, apiGroup *gin.RouterGroup, publicApiGroup *gin.RouterGroup) {
	// Gin's router doesn't handle WebDAV methods like PROPFIND, so we must register a global middleware here
	passwordAuth := server.auth.AuthMiddleware(true, "Access to WebDAV")
	handler := &webdav.Handler{
		Prefix:     PathPrefix,
		FileSystem: &delegatingFs{server, *server.logger.GetLogger("webdav.fs")},
		LockSystem: server.lockSystem,
		Logger:     makeLogger(server.logger),
	}
	app.Use(scoped(PathPrefix, false, func(ctx *gin.Context) {
		// redirect requests to "dav/" to "dav/p/"
		//TODO: doesn't seem to be understood by clients
		trimmed := strings.TrimPrefix(ctx.Request.URL.Path, PathPrefix)
		if trimmed == "" || trimmed == "/" {
			ctx.Redirect(http.StatusPermanentRedirect, PathPrefix+"/p")
		}
	}))
	app.Use(scoped(PathPrefix, false, func(ctx *gin.Context) {
		// access to shares "/dav/s" do not require authentication
		if !strings.HasPrefix(ctx.Request.URL.Path, PathPrefix+"/s") {
			passwordAuth(ctx)
		}
	}))
	app.Use(scoped(PathPrefix, false, CacheMiddleware()),
		scoped(PathPrefix, true, func(ctx *gin.Context) {
			spaceCache := make(map[string]spaces.SpaceResolveResponse)
			shareCache := make(map[string]shares.ShareResolveResponse)
			r := ctx.Request.WithContext(context.WithValue(ctx.Request.Context(), spaceResolveCacheKey{}, spaceCache))
			r = r.WithContext(context.WithValue(r.Context(), shareResolveCacheKey{}, shareCache))
			w := &fastResponseWriter{ctx.Writer}

			handler.ServeHTTP(w, r)
			ctx.Abort()
		}))
	app.Any("/dav/*path", func(*gin.Context) {
		// dummy method to prevent GIN returning 404
	})
}

func (server *webDavServer) FileSystem() webdav.FileSystem {
	return server.fs
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

func CacheMiddleware() func(*gin.Context) {
	return func(ctx *gin.Context) {
		spaceCache := make(map[string]spaces.SpaceResolveResponse)
		shareCache := make(map[string]shares.ShareResolveResponse)
		r := ctx.Request.WithContext(context.WithValue(ctx.Request.Context(), spaceResolveCacheKey{}, spaceCache))
		r = r.WithContext(context.WithValue(r.Context(), shareResolveCacheKey{}, shareCache))
		w := &fastResponseWriter{ctx.Writer}
		ctx.Writer = w
		ctx.Request = r
	}
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
