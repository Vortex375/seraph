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

package auth

import (
	"context"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/stretchr/testify/assert"
)

// handlers pass their *gin.Context; the middleware stores claims on the request context
func TestIsSpaceAdminWithGinContext(t *testing.T) {
	a := &oidcAuth{spaceAdminClaimKey: "roles"}
	ginCtx := func(roles ...any) *gin.Context {
		c, _ := gin.CreateTestContext(httptest.NewRecorder())
		req := httptest.NewRequest("GET", "/api/jobs", nil)
		c.Request = req.WithContext(context.WithValue(req.Context(), introspectionClaimsKey{}, map[string]any{"roles": roles}))
		return c
	}

	assert.True(t, a.IsSpaceAdmin(ginCtx("space-admin")))
	assert.True(t, a.IsSpaceAdmin(ginCtx("space-admin").Request.Context()))
	assert.False(t, a.IsSpaceAdmin(ginCtx("user")))
	assert.False(t, a.IsSpaceAdmin(ginCtx()))
}
