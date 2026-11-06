// Copyright © 2026 Benjamin Schmitz

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

package audio

import (
	"log/slog"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/nats-io/nats.go"
	"go.uber.org/fx"
	"umbasa.net/seraph/api-gateway/auth"
	"umbasa.net/seraph/api-gateway/gateway-handler"
	"umbasa.net/seraph/api-gateway/resourcefile"
	"umbasa.net/seraph/audio-metadata/audiometadata"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
)

var Module = fx.Module("audio",
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

type audioHandler struct {
	log      *slog.Logger
	nc       *nats.Conn
	resolver *resourcefile.Resolver
}

func New(p Params) Result {
	return Result{
		Handler: &audioHandler{
			log:      p.Log.GetLogger("audio"),
			nc:       p.Nc,
			resolver: resourcefile.New(p.Log, p.Nc, p.Auth),
		},
	}
}

// tagsResponse is the JSON answer: empty fields are left out, so the app
// treats a missing field as "no such tag".
type tagsResponse struct {
	Title       string `json:"title,omitempty"`
	Artist      string `json:"artist,omitempty"`
	Album       string `json:"album,omitempty"`
	AlbumArtist string `json:"albumArtist,omitempty"`
	Genre       string `json:"genre,omitempty"`
	Year        int    `json:"year,omitempty"`
	TrackNumber int    `json:"trackNumber,omitempty"`
	DiscNumber  int    `json:"discNumber,omitempty"`
	DurationMs  int64  `json:"durationMs,omitempty"`
	HasPicture  bool   `json:"hasPicture,omitempty"`
}

func (h *audioHandler) Setup(app *gin.Engine, apiGroup *gin.RouterGroup, publicApiGroup *gin.RouterGroup) {
	// Public like /preview: `s` resolves a share, `p` requires a login.
	app.GET("audio/tags", func(ctx *gin.Context) {
		providerId, filePath, ok := h.resolver.Resolve(ctx)
		if !ok {
			return
		}

		req := audiometadata.TagsRequest{
			ProviderID: providerId,
			Path:       filePath,
		}
		resp := audiometadata.TagsResponse{}
		err := messaging.Request(ctx.Request.Context(), h.nc, audiometadata.TagsRequestTopic, &req, &resp)
		if err != nil {
			h.log.Error("error retrieving tags response", "error", err)
			ctx.AbortWithStatus(http.StatusInternalServerError)
			return
		}

		switch resp.ErrorClass {
		case "":
			// read
		case audiometadata.ErrorClassNotFound:
			ctx.AbortWithStatus(http.StatusNotFound)
			return
		case audiometadata.ErrorClassUnsupported:
			ctx.AbortWithStatus(http.StatusUnsupportedMediaType)
			return
		default:
			h.log.Error("error retrieving tags", "class", resp.ErrorClass, "error", resp.Error)
			ctx.AbortWithStatus(http.StatusInternalServerError)
			return
		}
		if resp.Error != "" {
			h.log.Error("error retrieving tags", "error", resp.Error)
			ctx.AbortWithStatus(http.StatusInternalServerError)
			return
		}

		ctx.JSON(http.StatusOK, tagsResponse{
			Title:       resp.Title,
			Artist:      resp.Artist,
			Album:       resp.Album,
			AlbumArtist: resp.AlbumArtist,
			Genre:       resp.Genre,
			Year:        resp.Year,
			TrackNumber: resp.TrackNumber,
			DiscNumber:  resp.DiscNumber,
			DurationMs:  resp.DurationMs,
			HasPicture:  resp.HasPicture,
		})
	})
}
