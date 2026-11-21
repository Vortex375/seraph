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
	"encoding/json"
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
	apiGroup.GET("gallery/search", func(ctx *gin.Context) {
		limit := 0
		if l := ctx.Query("limit"); l != "" {
			parsed, err := strconv.Atoi(l)
			if err != nil || parsed < 0 {
				ctx.AbortWithError(http.StatusBadRequest, errors.New("invalid limit"))
				return
			}
			limit = parsed
		}

		req := gallery.GallerySearchRequest{
			UserId:   h.auth.GetUserId(ctx.Request.Context()),
			Text:     ctx.Query("q"),
			Tag:      ctx.Query("tag"),
			PersonId: ctx.Query("person"),
			Limit:    limit,
		}
		res := gallery.GallerySearchResponse{}
		if h.askAI(ctx, gallery.GallerySearchTopic, &req, &res, &res.Error) {
			ctx.JSON(http.StatusOK, res)
		}
	})

	apiGroup.GET("gallery/analysis/status", func(ctx *gin.Context) {
		req := gallery.GalleryAnalysisStatusRequest{UserId: h.auth.GetUserId(ctx.Request.Context())}
		res := gallery.GalleryAnalysisStatusResponse{}
		if h.askAI(ctx, gallery.GalleryAnalysisStatusTopic, &req, &res, &res.Error) {
			ctx.JSON(http.StatusOK, res)
		}
	})

	apiGroup.GET("gallery/people", func(ctx *gin.Context) {
		req := gallery.GalleryPeopleRequest{UserId: h.auth.GetUserId(ctx.Request.Context())}
		res := gallery.GalleryPeopleResponse{}
		if h.askAI(ctx, gallery.GalleryPeopleTopic, &req, &res, &res.Error) {
			ctx.JSON(http.StatusOK, res)
		}
	})

	apiGroup.PATCH("gallery/people/:id", func(ctx *gin.Context) {
		body := struct {
			Name *string `json:"name"`
		}{}
		if err := ctx.ShouldBindJSON(&body); err != nil || body.Name == nil {
			ctx.AbortWithError(http.StatusBadRequest, errors.New("name is required"))
			return
		}

		req := gallery.GalleryPersonRenameRequest{
			UserId: h.auth.GetUserId(ctx.Request.Context()),
			Id:     ctx.Param("id"),
			Name:   *body.Name,
		}
		res := gallery.GalleryPersonResponse{}
		if h.askAI(ctx, gallery.GalleryPeopleRenameTopic, &req, &res, &res.Error) {
			ctx.JSON(http.StatusOK, res)
		}
	})

	apiGroup.GET("gallery/photos/analysis", func(ctx *gin.Context) {
		providerId, photoPath := ctx.Query("providerId"), ctx.Query("path")
		if providerId == "" || !strings.HasPrefix(photoPath, "/") {
			ctx.AbortWithError(http.StatusBadRequest, errors.New("providerId and a path starting with '/' are required"))
			return
		}

		req := gallery.GalleryPhotoAnalysisRequest{
			UserId:     h.auth.GetUserId(ctx.Request.Context()),
			ProviderId: providerId,
			Path:       photoPath,
		}
		res := gallery.GalleryPhotoAnalysisResponse{}
		if h.askAI(ctx, gallery.GalleryPhotoAnalysisTopic, &req, &res, &res.Error) {
			ctx.JSON(http.StatusOK, res)
		}
	})

	apiGroup.PUT("gallery/faces/:id/person", func(ctx *gin.Context) {
		// exactly one of personId (string), newPersonName (string) or personId
		// null (unassign); an absent personId is different from a null one
		body := map[string]json.RawMessage{}
		if err := ctx.ShouldBindJSON(&body); err != nil {
			ctx.AbortWithError(http.StatusBadRequest, errors.New("invalid body"))
			return
		}
		rawPerson, hasPerson := body["personId"]
		rawName, hasName := body["newPersonName"]
		if hasPerson == hasName {
			ctx.AbortWithError(http.StatusBadRequest, errors.New("exactly one of personId and newPersonName is required"))
			return
		}

		req := gallery.GalleryFaceAssignRequest{
			UserId: h.auth.GetUserId(ctx.Request.Context()),
			FaceId: ctx.Param("id"),
		}
		raw := rawName
		if hasPerson {
			raw = rawPerson
		}
		var value *string
		if err := json.Unmarshal(raw, &value); err != nil || (value == nil && !hasPerson) || (value != nil && *value == "") {
			ctx.AbortWithError(http.StatusBadRequest, errors.New("personId and newPersonName must be non-empty strings (personId may be null)"))
			return
		}
		switch {
		case value == nil:
			req.Unassign = true
		case hasPerson:
			req.PersonId = *value
		default:
			req.NewPersonName = *value
		}

		res := gallery.GalleryFaceResponse{}
		if h.askAI(ctx, gallery.GalleryFacesAssignTopic, &req, &res, &res.Error) {
			ctx.JSON(http.StatusOK, res)
		}
	})
}

// askAI sends req to a gallery AI topic and decodes into res. It returns true
// when the response is usable; otherwise it has already aborted ctx:
// "ai-unavailable" is a 503 with a JSON body (the app detects it by that),
// "not found" a 404, any other error a 500.
func (h *galleryHandler) askAI(ctx *gin.Context, topic string, req any, res any, resError *string) bool {
	if err := messaging.Request(ctx.Request.Context(), h.nc, topic, messaging.Json(req), messaging.Json(res)); err != nil {
		ctx.AbortWithError(http.StatusInternalServerError, err)
		return false
	}
	switch *resError {
	case "":
		return true
	case gallery.ErrorAIUnavailable:
		ctx.AbortWithStatusJSON(http.StatusServiceUnavailable, gin.H{"error": gallery.ErrorAIUnavailable})
	case "not found":
		ctx.AbortWithError(http.StatusNotFound, errors.New(*resError))
	default:
		ctx.AbortWithError(http.StatusInternalServerError, errors.New(*resError))
	}
	return false
}

func (h *galleryHandler) request(ctx *gin.Context, req *gallery.GallerySourceFolderCrudRequest) (*gallery.GallerySourceFolderCrudResponse, error) {
	res := gallery.GallerySourceFolderCrudResponse{}
	err := messaging.Request(ctx.Request.Context(), h.nc, gallery.GallerySourceFolderCrudTopic, messaging.Json(req), messaging.Json(&res))
	if err != nil {
		return nil, err
	}
	return &res, nil
}
