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

package spaces

import (
	"errors"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/nats-io/nats.go"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.uber.org/fx"
	"umbasa.net/seraph/api-gateway/auth"
	"umbasa.net/seraph/api-gateway/gateway-handler"
	"umbasa.net/seraph/entities"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/spaces/spaces"
)

var Module = fx.Module("spaces",
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

type spacesHandler struct {
	logger *logging.Logger
	log    *slog.Logger
	nc     *nats.Conn
	auth   auth.Auth
}

func New(p Params) Result {
	return Result{
		Handler: &spacesHandler{
			logger: p.Log,
			log:    p.Log.GetLogger("spaces"),
			nc:     p.Nc,
			auth:   p.Auth,
		},
	}
}

func (h *spacesHandler) Setup(app *gin.Engine, apiGroup *gin.RouterGroup) {
	apiGroup.GET("spaces", func(ctx *gin.Context) {
		user := h.auth.GetUserId(ctx)
		isAdmin := h.auth.IsSpaceAdmin(ctx)

		req := spaces.SpaceCrudRequest{
			Operation: "READ",
			Space:     entities.MakePrototype(&spaces.SpacePrototype{}),
		}
		if !isAdmin {
			req.Space.Users.Set([]string{user})
		}

		res := spaces.SpaceCrudResponse{}
		err := messaging.Request(ctx.Request.Context(), h.nc, spaces.SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res))
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

	apiGroup.GET("spaces/:spaceId", func(ctx *gin.Context) {
		spaceId, err := primitive.ObjectIDFromHex(ctx.Param("spaceId"))
		if err != nil {
			ctx.AbortWithError(http.StatusBadRequest, fmt.Errorf("invalid space id: %w", err))
			return
		}

		user := h.auth.GetUserId(ctx)
		isAdmin := h.auth.IsSpaceAdmin(ctx)

		req := spaces.SpaceCrudRequest{
			Operation: "READ",
			Space:     entities.MakePrototype(&spaces.SpacePrototype{}),
		}
		req.Space.Id.Set(spaceId)
		if !isAdmin {
			req.Space.Users.Set([]string{user})
		}

		res := spaces.SpaceCrudResponse{}
		err = messaging.Request(ctx.Request.Context(), h.nc, spaces.SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res))
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

	apiGroup.POST("spaces", func(ctx *gin.Context) {
		isAdmin := h.auth.IsSpaceAdmin(ctx)
		if !isAdmin {
			ctx.AbortWithError(http.StatusForbidden, errors.New("only space admin can edit spaces"))
			return
		}

		space := entities.MakePrototype(&spaces.SpacePrototype{})
		err := ctx.BindJSON(space)

		if err != nil {
			h.log.Error("While creating space: error reading request", "error", err)
			return
		}

		req := spaces.SpaceCrudRequest{
			Operation: "CREATE",
			Space:     space,
		}
		res := spaces.SpaceCrudResponse{}
		err = messaging.Request(ctx.Request.Context(), h.nc, spaces.SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res))
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

	apiGroup.PUT("spaces/:spaceId", func(ctx *gin.Context) {
		isAdmin := h.auth.IsSpaceAdmin(ctx)
		if !isAdmin {
			ctx.AbortWithError(http.StatusForbidden, errors.New("only space admin can edit spaces"))
			return
		}

		spaceId, err := primitive.ObjectIDFromHex(ctx.Param("spaceId"))
		if err != nil {
			ctx.AbortWithError(http.StatusBadRequest, fmt.Errorf("invalid space id: %w", err))
			return
		}

		space := entities.MakePrototype(&spaces.SpacePrototype{})
		err = ctx.BindJSON(space)
		if err != nil {
			h.log.Error("While creating space: error reading request", "error", err)
			return
		}

		space.Id.Set(spaceId)

		req := spaces.SpaceCrudRequest{
			Operation: "UPDATE",
			Space:     space,
		}
		res := spaces.SpaceCrudResponse{}
		err = messaging.Request(ctx.Request.Context(), h.nc, spaces.SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res))
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

	apiGroup.DELETE("spaces/:spaceId", func(ctx *gin.Context) {
		isAdmin := h.auth.IsSpaceAdmin(ctx)
		if !isAdmin {
			ctx.AbortWithError(http.StatusForbidden, errors.New("only space admin can edit spaces"))
			return
		}

		spaceId, err := primitive.ObjectIDFromHex(ctx.Param("spaceId"))
		if err != nil {
			ctx.AbortWithError(http.StatusBadRequest, fmt.Errorf("invalid space id: %w", err))
			return
		}

		space := entities.MakePrototype(&spaces.SpacePrototype{})
		space.Id.Set(spaceId)

		req := spaces.SpaceCrudRequest{
			Operation: "DELETE",
			Space:     space,
		}
		res := spaces.SpaceCrudResponse{}
		err = messaging.Request(ctx.Request.Context(), h.nc, spaces.SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res))
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
