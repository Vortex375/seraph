package shares

import (
	"errors"
	"log/slog"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/nats-io/nats.go"
	"go.uber.org/fx"
	"umbasa.net/seraph/api-gateway/auth"
	"umbasa.net/seraph/api-gateway/gateway-handler"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/shares/shares"
)

var Module = fx.Module("shares",
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

type sharesHandler struct {
	logger *logging.Logger
	log    *slog.Logger
	nc     *nats.Conn
	auth   auth.Auth
}

func New(p Params) Result {
	return Result{
		Handler: &sharesHandler{
			logger: p.Log,
			log:    p.Log.GetLogger("shares"),
			nc:     p.Nc,
			auth:   p.Auth,
		},
	}
}

func (h *sharesHandler) Setup(app *gin.Engine, apiGroup *gin.RouterGroup) {
	apiGroup.GET("shares/:shareId", func(ctx *gin.Context) {
		shareId := ctx.Param("shareId")

		req := shares.ShareCrudRequest{
			Operation: "READ",
			Share: &shares.Share{
				ShareID: shareId,
			},
		}
		res := shares.ShareCrudResponse{}
		err := messaging.Request(h.nc, shares.ShareCrudTopic, &req, &res)
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, err)
			return
		}
		if res.Error != "" {
			//TODO: make better
			ctx.AbortWithError(http.StatusInternalServerError, errors.New(res.Error))
			return
		}

		ctx.JSON(http.StatusOK, res)
	})

	apiGroup.POST("shares", func(ctx *gin.Context) {
		share := shares.Share{}
		err := ctx.BindJSON(&share)

		if err != nil {
			h.log.Error("While creating share: error reading request", "error", err)
			return
		}

		req := shares.ShareCrudRequest{
			Operation: "CREATE",
			Share:     &share,
		}
		res := shares.ShareCrudResponse{}
		err = messaging.Request(h.nc, shares.ShareCrudTopic, &req, &res)
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, err)
			return
		}
		if res.Error != "" {
			//TODO: make better
			ctx.AbortWithError(http.StatusInternalServerError, errors.New(res.Error))
			return
		}

		ctx.JSON(http.StatusCreated, res)
	})

	apiGroup.PUT("shares/:shareId", func(ctx *gin.Context) {
		shareId := ctx.Param("shareId")

		share := shares.Share{}
		err := ctx.BindJSON(&share)

		if err != nil {
			h.log.Error("While creating share: error reading request", "error", err)
			return
		}

		share.ShareID = shareId

		req := shares.ShareCrudRequest{
			Operation: "UPDATE",
			Share:     &share,
		}
		res := shares.ShareCrudResponse{}
		err = messaging.Request(h.nc, shares.ShareCrudTopic, &req, &res)
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, err)
			return
		}
		if res.Error != "" {
			//TODO: make better
			ctx.AbortWithError(http.StatusInternalServerError, errors.New(res.Error))
			return
		}

		ctx.JSON(http.StatusOK, res)
	})

	apiGroup.DELETE("shares/:shareId", func(ctx *gin.Context) {
		shareId := ctx.Param("shareId")
		share := shares.Share{
			ShareID: shareId,
		}

		req := shares.ShareCrudRequest{
			Operation: "DELETE",
			Share:     &share,
		}
		res := shares.ShareCrudResponse{}
		err := messaging.Request(h.nc, shares.ShareCrudTopic, &req, &res)
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, err)
			return
		}
		if res.Error != "" {
			//TODO: make better
			ctx.AbortWithError(http.StatusInternalServerError, errors.New(res.Error))
			return
		}

		ctx.JSON(http.StatusOK, res)
	})

}
