package services

import (
	"errors"
	"log/slog"
	"net/http"

	"github.com/gin-gonic/gin"
	"go.uber.org/fx"
	"umbasa.net/seraph/api-gateway/auth"
	"umbasa.net/seraph/api-gateway/gateway-handler"
	"umbasa.net/seraph/logging"
	servicediscovery "umbasa.net/seraph/service-discovery"
)

var Module = fx.Module("services",
	fx.Provide(
		New,
	),
)

type Params struct {
	fx.In

	Log       *logging.Logger
	Discovery servicediscovery.ServiceDiscovery
	Auth      auth.Auth
}

type Result struct {
	fx.Out

	Handler gateway.GatewayHandler `group:"gatewayhandlers"`
}

type servicesHandler struct {
	log       *slog.Logger
	discovery servicediscovery.ServiceDiscovery
	auth      auth.Auth
}

func New(p Params) Result {
	return Result{
		Handler: &servicesHandler{
			log:       p.Log.GetLogger("services"),
			discovery: p.Discovery,
			auth:      p.Auth,
		},
	}
}

func (h *servicesHandler) Setup(app *gin.Engine, apiGroup *gin.RouterGroup, publicApiGroup *gin.RouterGroup) {
	apiGroup.GET("/services", func(ctx *gin.Context) {
		if !h.auth.IsSpaceAdmin(ctx) {
			ctx.AbortWithError(http.StatusForbidden, errors.New("only space admin can access services"))
			return
		}
		ctx.JSON(200, h.discovery.Get(""))
	})
	apiGroup.GET("/services/type/:serviceType", func(ctx *gin.Context) {
		if !h.auth.IsSpaceAdmin(ctx) {
			ctx.AbortWithError(http.StatusForbidden, errors.New("only space admin can access services"))
			return
		}
		ctx.JSON(200, h.discovery.Get(ctx.Param("serviceType")))
	})
}
