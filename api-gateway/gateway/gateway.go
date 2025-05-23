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

package gateway

import (
	"context"
	"log/slog"
	"net/http"

	"github.com/Cyprinus12138/otelgin"
	"github.com/gin-contrib/sessions"
	"github.com/gin-contrib/sessions/memstore"
	"github.com/gin-gonic/gin"
	"github.com/spf13/viper"
	cachecontrol "go.eigsys.de/gin-cachecontrol/v2"
	"go.uber.org/fx"
	"umbasa.net/seraph/api-gateway/auth"
	handler "umbasa.net/seraph/api-gateway/gateway-handler"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/tracing"

	sloggin "github.com/samber/slog-gin"
)

var Module = fx.Module("gateway",
	fx.Provide(
		New,
	),
)

type Params struct {
	fx.In

	Log      *logging.Logger
	Viper    *viper.Viper
	Auth     auth.Auth
	Tracing  *tracing.Tracing
	Handlers []handler.GatewayHandler `group:"gatewayhandlers"`
	Lc       fx.Lifecycle
}

type Result struct {
	fx.Out

	Gateway Gateway
}

type Gateway interface {
	Start(handlers []handler.GatewayHandler)
	Stop()
}

type gateway struct {
	logging *logging.Logger
	log     *slog.Logger
	viper   *viper.Viper
	auth    auth.Auth
	server  *http.Server
}

func New(p Params) Result {
	p.Viper.SetDefault("gateway.cookie.secret", "secret")
	p.Viper.SetDefault("gateway.address", ":8080")
	p.Viper.SetDefault("gateway.appLocation", "/srv/app")
	p.Viper.SetDefault("gateway.webAppLocation", "/srv/webapp")

	gateway := &gateway{
		logging: p.Log,
		log:     p.Log.GetLogger("api-gateway"),
		viper:   p.Viper,
		auth:    p.Auth,
	}

	p.Lc.Append(fx.StartHook(func() {
		gateway.Start(p.Handlers)
	}))
	p.Lc.Append(fx.StopHook(gateway.Stop))

	return Result{Gateway: gateway}
}

func (g *gateway) Start(handlers []handler.GatewayHandler) {
	engine := gin.New()
	engine.Use(sloggin.New(g.logging.GetLogger("gin")))
	engine.Use(gin.Recovery())
	engine.Use(otelgin.Middleware("api-gateway"))

	//TODO: secret
	store := memstore.NewStore([]byte(g.viper.GetString("gateway.cookie.secret")))
	store.Options(sessions.Options{
		Path:     "/",
		Secure:   true,
		HttpOnly: true,
		// SameSite: http.SameSiteStrictMode,
	})
	engine.Use(sessions.Sessions("seraphsession", store))

	authMiddleware := g.auth.AuthMiddleware(false, "")

	apiGroup := engine.Group("/api", cachecontrol.New(cachecontrol.NoCachePreset), func(ctx *gin.Context) { authMiddleware(ctx) })
	apiGroup.GET("/test", getTest)

	publicApiGroup := engine.Group("/public-api", cachecontrol.New(cachecontrol.NoCachePreset))
	publicApiGroup.GET("/test", getTest)

	appGroup := engine.Group("/app",
		func(ctx *gin.Context) {
			path := ctx.Request.URL.Path
			if path == "/app" || path == "/app/" || path == "/app/index.html" {
				ctx.Header("Cache-Control", "no-cache")
			}
		},
	)
	appLocation := g.viper.GetString("gateway.appLocation")
	appGroup.Static("/", appLocation)

	webAppGroup := engine.Group("/webapp", func(ctx *gin.Context) { authMiddleware(ctx) })
	webAppLocation := g.viper.GetString("gateway.webAppLocation")
	webAppGroup.Static("/", webAppLocation)

	engine.GET("/", getRoot)

	for _, handler := range handlers {
		handler.Setup(engine, apiGroup, publicApiGroup)
	}

	address := g.viper.GetString("gateway.address")
	g.server = &http.Server{
		Addr:    address,
		Handler: engine.Handler(),
	}

	go g.server.ListenAndServe()

	g.log.Info("HTTP Server listening on " + address)
}

func (g *gateway) Stop() {
	if g.server == nil {
		return
	}
	g.server.Shutdown(context.Background())
	g.server = nil
	g.log.Info("HTTP Server closed")
}

func getRoot(ctx *gin.Context) {
	ctx.Redirect(http.StatusFound, "/app")
}

func getTest(ctx *gin.Context) {
	ctx.String(http.StatusOK, "Hello from API!")
}
