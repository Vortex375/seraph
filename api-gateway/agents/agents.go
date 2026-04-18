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

package agents

import (
	"errors"
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/spf13/viper"
	"go.uber.org/fx"
	apiAuth "umbasa.net/seraph/api-gateway/auth"
	"umbasa.net/seraph/api-gateway/gateway-handler"
	"umbasa.net/seraph/logging"
)

const seraphUserHeader = "X-Seraph-User"

var Module = fx.Module("agents",
	fx.Provide(
		New,
	),
)

type Params struct {
	fx.In

	Log   *logging.Logger
	Viper *viper.Viper
	Auth  apiAuth.Auth
}

type Result struct {
	fx.Out

	Handler gateway.GatewayHandler `group:"gatewayhandlers"`
}

type agentsHandler struct {
	log   *slog.Logger
	auth  apiAuth.Auth
	proxy *httputil.ReverseProxy
}

func New(p Params) (Result, error) {
	p.Viper.SetDefault("gateway.agents.baseURL", "http://agents-api:8000")

	baseURL := strings.TrimSpace(p.Viper.GetString("gateway.agents.baseURL"))
	if baseURL == "" {
		return Result{}, errors.New("gateway.agents.baseURL must not be empty")
	}

	target, err := url.Parse(baseURL)
	if err != nil {
		return Result{}, err
	}

	proxy := httputil.NewSingleHostReverseProxy(target)
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		if req.Host == "" {
			req.Host = target.Host
		}
	}

	return Result{
		Handler: &agentsHandler{
			log:   p.Log.GetLogger("agents"),
			auth:  p.Auth,
			proxy: proxy,
		},
	}, nil
}

func (h *agentsHandler) Setup(app *gin.Engine, apiGroup *gin.RouterGroup, publicApiGroup *gin.RouterGroup) {
	_ = app
	_ = publicApiGroup
	handleProxy := func(ctx *gin.Context) {
		userID := h.auth.GetUserId(ctx.Request.Context())
		if userID != "" {
			ctx.Request.Header.Set(seraphUserHeader, userID)
		}
		h.proxy.ServeHTTP(ctx.Writer, ctx.Request)
	}

	apiGroup.Any("/v1/chat/*path", handleProxy)
	apiGroup.Any("/v1/chat", handleProxy)
	apiGroup.Any("/v1/documents/*path", handleProxy)
	apiGroup.Any("/v1/documents", handleProxy)

	h.log.Info("agents API proxy enabled")
}
