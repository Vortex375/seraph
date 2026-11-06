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

// Package resourcefile resolves the gateway's `?p=` (space path) / `?s=`
// (share path) file parameters to a file provider id and a file path. The
// preview and the audio tags endpoints share it.
package resourcefile

import (
	"log/slog"
	"net/http"
	"path"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/nats-io/nats.go"
	"umbasa.net/seraph/api-gateway/auth"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/shares/shares"
	"umbasa.net/seraph/spaces/spaces"
)

// Resolver turns a request's file parameter into provider id and file path.
type Resolver struct {
	log         *slog.Logger
	nc          *nats.Conn
	auth        auth.Auth
	authHandler func(*gin.Context) bool
}

func New(logger *logging.Logger, nc *nats.Conn, auth auth.Auth) *Resolver {
	return &Resolver{
		log:         logger.GetLogger("resourcefile"),
		nc:          nc,
		auth:        auth,
		authHandler: auth.AuthMiddleware(false, ""),
	}
}

// Resolve answers the request with 400, 401/403 (via auth), 404 or 500 and
// returns false when the parameters are not valid or resolve to no file. A
// `p` path needs a logged-in user; an `s` path is resolved as a share, which
// is accessible without one.
func (r *Resolver) Resolve(ctx *gin.Context) (providerId string, filePath string, ok bool) {
	parameterP := ctx.Query("p")
	parameterS := ctx.Query("s")

	if parameterP != "" && parameterS != "" {
		r.log.Error("both 'p' and 's' specified - only one can be used")
		ctx.AbortWithStatus(http.StatusBadRequest)
		return "", "", false
	}

	if parameterP == "" && parameterS == "" {
		r.log.Error("missing 'p' or 's' parameter")
		ctx.AbortWithStatus(http.StatusBadRequest)
		return "", "", false
	}

	if parameterS != "" {
		shareId, sharePath := splitProviderAndPath(parameterS)
		resolveReq := shares.ShareResolveRequest{
			ShareId: shareId,
			Path:    sharePath,
		}
		resolveRes := shares.ShareResolveResponse{}
		err := messaging.Request(ctx.Request.Context(), r.nc, shares.ShareResolveTopic, messaging.Json(&resolveReq), messaging.Json(&resolveRes))
		if err != nil {
			r.log.Error("error while resolving share", "error", err)
			ctx.AbortWithStatus(http.StatusInternalServerError)
			return "", "", false
		}
		if resolveRes.Error != "" {
			r.log.Error("error while resolving share", "error", resolveRes.Error)
			ctx.AbortWithStatus(http.StatusInternalServerError)
			return "", "", false
		}
		if resolveRes.ProviderId == "" {
			ctx.AbortWithStatus(http.StatusNotFound)
			return "", "", false
		}

		return resolveRes.ProviderId, resolveRes.Path, true
	}

	if !r.authHandler(ctx) {
		return "", "", false
	}

	spaceProviderId, spacePath := splitProviderAndPath(parameterP)
	if spaceProviderId == "" || spacePath == "" {
		r.log.Error("path must include providerId and path resp. filename")
		ctx.AbortWithStatus(http.StatusBadRequest)
		return "", "", false
	}

	resolveReq := spaces.SpaceResolveRequest{
		UserId:          r.auth.GetUserId(ctx.Request.Context()),
		SpaceProviderId: spaceProviderId,
	}
	resolveRes := spaces.SpaceResolveResponse{}
	err := messaging.Request(ctx.Request.Context(), r.nc, spaces.SpaceResolveTopic, messaging.Json(&resolveReq), messaging.Json(&resolveRes))
	if err != nil {
		r.log.Error("error while resolving space", "error", err)
		ctx.AbortWithStatus(http.StatusInternalServerError)
		return "", "", false
	}
	if resolveRes.Error != "" {
		r.log.Error("error while resolving space", "error", resolveRes.Error)
		ctx.AbortWithStatus(http.StatusInternalServerError)
		return "", "", false
	}
	if resolveRes.ProviderId == "" {
		ctx.AbortWithStatus(http.StatusNotFound)
		return "", "", false
	}

	return resolveRes.ProviderId, path.Join(resolveRes.Path, spacePath), true
}

func splitProviderAndPath(p string) (string, string) {
	split := strings.SplitN(strings.TrimPrefix(p, "/"), "/", 2)

	if len(split) == 1 {
		return split[0], ""
	}

	if len(split) == 2 {
		return split[0], split[1]
	}

	return "", ""
}
