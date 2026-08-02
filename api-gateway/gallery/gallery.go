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

package gallery

import (
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/nats-io/nats.go"
	"go.uber.org/fx"
	"umbasa.net/seraph/api-gateway/auth"
	"umbasa.net/seraph/api-gateway/gateway-handler"
	"umbasa.net/seraph/gallery/gallery"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
)

var Module = fx.Module("gallery",
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

type galleryHandler struct {
	log  *slog.Logger
	nc   *nats.Conn
	auth auth.Auth
}

// addSourceFolderRequest is the request body for adding a Gallery Source
// Folder. The folder is given in Space terms, exactly as picked in the folder
// picker. The owning user is never taken from the body - always from the
// authenticated session.
type addSourceFolderRequest struct {
	SpaceProviderId string `json:"spaceProviderId"`
	Path            string `json:"path"`
}

func New(p Params) Result {
	return Result{
		Handler: &galleryHandler{
			log:  p.Log.GetLogger("gallery"),
			nc:   p.Nc,
			auth: p.Auth,
		},
	}
}

func (h *galleryHandler) Setup(app *gin.Engine, apiGroup *gin.RouterGroup, publicApiGroup *gin.RouterGroup) {
	apiGroup.GET("gallery/source-folders", func(ctx *gin.Context) {
		req := gallery.GallerySourceFolderCrudRequest{
			Operation: gallery.GallerySourceFolderOperationList,
			UserId:    h.auth.GetUserId(ctx.Request.Context()),
		}

		res, err := h.request(ctx, &req)
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, err)
			return
		}

		if res.Error != "" {
			ctx.AbortWithError(http.StatusInternalServerError, errors.New(res.Error))
			return
		}

		ctx.JSON(http.StatusOK, res)
	})

	apiGroup.POST("gallery/source-folders", func(ctx *gin.Context) {
		body := addSourceFolderRequest{}
		if err := ctx.BindJSON(&body); err != nil {
			h.log.Error("while adding gallery source folder: error reading request", "error", err)
			return
		}

		if body.SpaceProviderId == "" {
			ctx.AbortWithError(http.StatusBadRequest, errors.New("spaceProviderId is required"))
			return
		}
		if body.Path == "" || !strings.HasPrefix(body.Path, "/") {
			ctx.AbortWithError(http.StatusBadRequest, errors.New("path is required and must start with '/'"))
			return
		}

		req := gallery.GallerySourceFolderCrudRequest{
			Operation:       gallery.GallerySourceFolderOperationAdd,
			UserId:          h.auth.GetUserId(ctx.Request.Context()),
			SpaceProviderId: body.SpaceProviderId,
			Path:            body.Path,
		}

		res, err := h.request(ctx, &req)
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, err)
			return
		}

		if res.Error != "" {
			// the request was well-formed, so the only remaining reason the
			// gallery service refuses an add is that the user has no access to
			// the space the folder lives in
			ctx.AbortWithError(http.StatusForbidden, errors.New(res.Error))
			return
		}

		ctx.JSON(http.StatusCreated, res)
	})

	apiGroup.GET("gallery/photos", func(ctx *gin.Context) {
		pageSize := 0
		if ps := ctx.Query("pageSize"); ps != "" {
			parsed, err := strconv.Atoi(ps)
			if err != nil {
				ctx.AbortWithError(http.StatusBadRequest, errors.New("invalid pageSize"))
				return
			}
			pageSize = parsed
		}

		req := gallery.GalleryListRequest{
			UserId:   h.auth.GetUserId(ctx.Request.Context()),
			PageSize: pageSize,
			Cursor:   ctx.Query("cursor"),
		}

		res := gallery.GalleryListResponse{}
		if err := messaging.Request(ctx.Request.Context(), h.nc, gallery.GalleryListTopic, messaging.Json(&req), messaging.Json(&res)); err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, err)
			return
		}

		if res.Error != "" {
			ctx.AbortWithError(http.StatusInternalServerError, errors.New(res.Error))
			return
		}

		ctx.JSON(http.StatusOK, res)
	})

	apiGroup.GET("gallery/delta", func(ctx *gin.Context) {
		since := int64(0)
		if s := ctx.Query("since"); s != "" {
			parsed, err := strconv.ParseInt(s, 10, 64)
			if err != nil {
				ctx.AbortWithError(http.StatusBadRequest, errors.New("invalid since"))
				return
			}
			since = parsed
		}

		pageSize := 0
		if ps := ctx.Query("pageSize"); ps != "" {
			parsed, err := strconv.Atoi(ps)
			if err != nil {
				ctx.AbortWithError(http.StatusBadRequest, errors.New("invalid pageSize"))
				return
			}
			pageSize = parsed
		}

		req := gallery.GalleryDeltaRequest{
			UserId:   h.auth.GetUserId(ctx.Request.Context()),
			Since:    since,
			PageSize: pageSize,
			Cursor:   ctx.Query("cursor"),
		}

		res := gallery.GalleryDeltaResponse{}
		if err := messaging.Request(ctx.Request.Context(), h.nc, gallery.GalleryDeltaTopic, messaging.Json(&req), messaging.Json(&res)); err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, err)
			return
		}

		if res.Error != "" {
			ctx.AbortWithError(http.StatusInternalServerError, errors.New(res.Error))
			return
		}

		ctx.JSON(http.StatusOK, res)
	})

	apiGroup.POST("gallery/source-folders/:sourceFolderId/rescan", func(ctx *gin.Context) {
		sourceFolderId := ctx.Param("sourceFolderId")

		req := gallery.GallerySourceFolderCrudRequest{
			Operation: gallery.GallerySourceFolderOperationRescan,
			UserId:    h.auth.GetUserId(ctx.Request.Context()),
			Id:        sourceFolderId,
		}

		res, err := h.request(ctx, &req)
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, err)
			return
		}

		if res.Error != "" {
			// rescan is scoped to the requesting user inside the gallery
			// service, so another user's folder is simply not found
			ctx.AbortWithError(http.StatusNotFound, errors.New(res.Error))
			return
		}

		ctx.JSON(http.StatusAccepted, res)
	})

	apiGroup.DELETE("gallery/source-folders/:sourceFolderId", func(ctx *gin.Context) {
		sourceFolderId := ctx.Param("sourceFolderId")

		req := gallery.GallerySourceFolderCrudRequest{
			Operation: gallery.GallerySourceFolderOperationRemove,
			UserId:    h.auth.GetUserId(ctx.Request.Context()),
			Id:        sourceFolderId,
		}

		res, err := h.request(ctx, &req)
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, err)
			return
		}

		if res.Error != "" {
			// removal is scoped to the requesting user inside the gallery
			// service, so another user's folder is simply not found
			ctx.AbortWithError(http.StatusNotFound, errors.New(res.Error))
			return
		}

		ctx.JSON(http.StatusOK, res)
	})
}

func (h *galleryHandler) request(ctx *gin.Context, req *gallery.GallerySourceFolderCrudRequest) (*gallery.GallerySourceFolderCrudResponse, error) {
	res := gallery.GallerySourceFolderCrudResponse{}
	err := messaging.Request(ctx.Request.Context(), h.nc, gallery.GallerySourceFolderCrudTopic, messaging.Json(req), messaging.Json(&res))
	if err != nil {
		return nil, err
	}
	return &res, nil
}
