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
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/spf13/viper"
	"github.com/stretchr/testify/assert"
	apiAuth "umbasa.net/seraph/api-gateway/auth"
	"umbasa.net/seraph/logging"
)

func TestChatRequestsAreProxiedToAgentsAPI(t *testing.T) {
	gin.SetMode(gin.TestMode)

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		assert.Equal(t, "/api/v1/chat/sessions", r.URL.Path)
		assert.Equal(t, "limit=10", r.URL.RawQuery)
		assert.Equal(t, "anonymous", r.Header.Get("X-Seraph-User"))
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `[{"id":"session-1"}]`)
	}))
	defer upstream.Close()

	logger := logging.New(logging.Params{})
	config := viper.New()
	config.Set("auth.enabled", false)
	config.Set("gateway.agents.baseURL", upstream.URL)

	authResult, err := apiAuth.New(apiAuth.Params{
		Log:   logger,
		Viper: config,
	})
	if err != nil {
		t.Fatal(err)
	}

	result, err := New(Params{
		Log:   logger,
		Viper: config,
		Auth:  authResult.Auth,
	})
	if err != nil {
		t.Fatal(err)
	}

	app := gin.New()
	apiGroup := app.Group("/api")
	publicGroup := app.Group("/public")
	result.Handler.Setup(app, apiGroup, publicGroup)
	server := httptest.NewServer(app)
	defer server.Close()

	response, err := http.Get(server.URL + "/api/v1/chat/sessions?limit=10")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, http.StatusOK, response.StatusCode)
	assert.JSONEq(t, `[{"id":"session-1"}]`, string(body))
}
