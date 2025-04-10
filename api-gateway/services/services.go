package services

import (
	"log/slog"

	"github.com/gin-gonic/gin"
	"go.uber.org/fx"
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
}

type Result struct {
	fx.Out

	Handler gateway.GatewayHandler `group:"gatewayhandlers"`
}

type servicesHandler struct {
	log       *slog.Logger
	discovery servicediscovery.ServiceDiscovery
}

func New(p Params) Result {
	return Result{
		Handler: &servicesHandler{
			log:       p.Log.GetLogger("services"),
			discovery: p.Discovery,
		},
	}
}

func (h *servicesHandler) Setup(app *gin.Engine, apiGroup *gin.RouterGroup, publicApiGroup *gin.RouterGroup) {
	apiGroup.GET("/services", func(ctx *gin.Context) {
		ctx.JSON(200, h.discovery.Get(""))
	})
	apiGroup.GET("/services/type/:serviceType", func(ctx *gin.Context) {
		ctx.JSON(200, h.discovery.Get(ctx.Param("serviceType")))
	})
}
