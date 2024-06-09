package gateway

import (
	"context"
	"log/slog"
	"net/http"

	"github.com/gin-contrib/sessions"
	"github.com/gin-contrib/sessions/memstore"
	"github.com/gin-gonic/gin"
	"github.com/spf13/viper"
	cachecontrol "go.eigsys.de/gin-cachecontrol/v2"
	"go.uber.org/fx"
	"umbasa.net/seraph/api-gateway/auth"
	handler "umbasa.net/seraph/api-gateway/gateway-handler"
	"umbasa.net/seraph/logging"
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
	log    *slog.Logger
	viper  *viper.Viper
	auth   auth.Auth
	server *http.Server
}

func New(p Params) Result {
	p.Viper.SetDefault("gateway.cookie.secret", "secret")
	p.Viper.SetDefault("gateway.address", ":8080")

	gateway := &gateway{
		log:   p.Log.GetLogger("api-gateway"),
		viper: p.Viper,
		auth:  p.Auth,
	}

	p.Lc.Append(fx.StartHook(func() {
		gateway.Start(p.Handlers)
	}))
	p.Lc.Append(fx.StopHook(gateway.Stop))

	return Result{Gateway: gateway}
}

func (g *gateway) Start(handlers []handler.GatewayHandler) {
	engine := gin.Default()

	//TODO: secret
	store := memstore.NewStore([]byte(g.viper.GetString("gateway.cookie.secret")))
	store.Options(sessions.Options{
		Path:     "/",
		Secure:   true,
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
	})
	engine.Use(sessions.Sessions("mysession", store))

	apiGroup := engine.Group("/api", cachecontrol.New(cachecontrol.NoCachePreset), g.auth.AuthMiddleware())
	apiGroup.GET("/test", getTest)

	engine.GET("/", getRoot)

	for _, handler := range handlers {
		handler.Setup(engine, apiGroup)
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
	ctx.String(http.StatusOK, "Hello, World!")
}

func getTest(ctx *gin.Context) {
	ctx.String(http.StatusOK, "Hello from API!")
}
