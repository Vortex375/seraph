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
	"umbasa.net/seraph/entities"
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
		owner := h.auth.GetUserId(ctx)

		req := shares.ShareCrudRequest{
			Operation: "READ",
			Share:     entities.MakePrototype(&shares.SharePrototype{}),
		}
		req.Share.ShareId.Set(shareId)
		req.Share.Owner.Set(owner)

		res := shares.ShareCrudResponse{}
		err := messaging.Request(ctx.Request.Context(), h.nc, shares.ShareCrudTopic, messaging.Json(&req), messaging.Json(&res))
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
		share := entities.MakePrototype(&shares.SharePrototype{})
		err := ctx.BindJSON(share)

		if err != nil {
			h.log.Error("While creating share: error reading request", "error", err)
			return
		}

		owner := h.auth.GetUserId(ctx)
		share.Owner.Set(owner)

		req := shares.ShareCrudRequest{
			Operation: "CREATE",
			Share:     share,
		}
		res := shares.ShareCrudResponse{}
		err = messaging.Request(ctx.Request.Context(), h.nc, shares.ShareCrudTopic, messaging.Json(&req), messaging.Json(&res))
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

		share := entities.MakePrototype(&shares.SharePrototype{})
		err := ctx.BindJSON(share)

		if err != nil {
			h.log.Error("While creating share: error reading request", "error", err)
			return
		}

		owner := h.auth.GetUserId(ctx)
		share.Owner.Set(owner)
		share.ShareId.Set(shareId)

		req := shares.ShareCrudRequest{
			Operation: "UPDATE",
			Share:     share,
		}
		res := shares.ShareCrudResponse{}
		err = messaging.Request(ctx.Request.Context(), h.nc, shares.ShareCrudTopic, messaging.Json(&req), messaging.Json(&res))
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
		share := entities.MakePrototype(&shares.SharePrototype{})
		owner := h.auth.GetUserId(ctx)
		share.ShareId.Set(shareId)
		share.Owner.Set(owner)

		req := shares.ShareCrudRequest{
			Operation: "DELETE",
			Share:     share,
		}
		res := shares.ShareCrudResponse{}
		err := messaging.Request(ctx.Request.Context(), h.nc, shares.ShareCrudTopic, messaging.Json(&req), messaging.Json(&res))
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
