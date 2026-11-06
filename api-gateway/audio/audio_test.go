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
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"umbasa.net/seraph/api-gateway/auth"
	"umbasa.net/seraph/api-gateway/resourcefile"
	"umbasa.net/seraph/audio-metadata/audiometadata"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/shares/shares"
	"umbasa.net/seraph/spaces/spaces"
)

func TestAudioTags(t *testing.T) {
	gin.SetMode(gin.TestMode)

	natsServer, err := server.NewServer(&server.Options{
		Host:   "127.0.0.1",
		Port:   -1,
		NoLog:  true,
		NoSigs: true,
	})
	require.NoError(t, err)
	natsServer.Start()
	defer natsServer.Shutdown()

	var nc *nats.Conn
	nc, err = nats.Connect(natsServer.ClientURL())
	require.NoError(t, err)
	defer nc.Close()

	// Reply the space/share resolution for any request, and record the tags
	// requests the handler sends.
	var tagRequests []audiometadata.TagsRequest
	spaceSub, err := nc.Subscribe(spaces.SpaceResolveTopic, func(msg *nats.Msg) {
		res := spaces.SpaceResolveResponse{ProviderId: "resolved", Path: "/space"}
		data, _ := json.Marshal(&res)
		msg.Respond(data)
	})
	require.NoError(t, err)
	defer spaceSub.Unsubscribe()

	shareSub, err := nc.Subscribe(shares.ShareResolveTopic, func(msg *nats.Msg) {
		res := shares.ShareResolveResponse{ProviderId: "shared", Path: "/share/file.mp3"}
		data, _ := json.Marshal(&res)
		msg.Respond(data)
	})
	require.NoError(t, err)
	defer shareSub.Unsubscribe()

	tagsSub, err := nc.Subscribe(audiometadata.TagsRequestTopic, func(msg *nats.Msg) {
		req := audiometadata.TagsRequest{}
		require.NoError(t, req.Unmarshal(msg.Data))
		tagRequests = append(tagRequests, req)
		resp := audiometadata.TagsResponse{Title: "The Title", Artist: "The Artist", TrackNumber: 3}
		if req.Path == "/space/other.flac" {
			resp = audiometadata.TagsResponse{ErrorClass: audiometadata.ErrorClassUnsupported}
		}
		data, _ := resp.Marshal()
		msg.Respond(data)
	})
	require.NoError(t, err)
	defer tagsSub.Unsubscribe()

	logger := logging.New(logging.Params{})
	handler := &audioHandler{
		log:      logger.GetLogger("audio"),
		nc:       nc,
		resolver: resourcefile.New(logger, nc, allowAllAuth{}),
	}
	engine := gin.New()
	handler.Setup(engine, engine.Group("/api"), engine.Group("/public-api"))

	get := func(query url.Values) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, "/audio/tags?"+query.Encode(), nil)
		engine.ServeHTTP(rec, req)
		return rec
	}

	t.Run("space path", func(t *testing.T) {
		tagRequests = nil
		rec := get(url.Values{"p": {"/music/file.mp3"}})
		require.Equal(t, http.StatusOK, rec.Code, rec.Body.String())

		// "music" is the Space's provider id; the rest is joined with the
		// Space's path, as for /preview.
		assert.Equal(t, []audiometadata.TagsRequest{{ProviderID: "resolved", Path: "/space/file.mp3"}}, tagRequests)

		// Empty fields are omitted.
		assert.JSONEq(t, `{"title":"The Title","artist":"The Artist","trackNumber":3}`, rec.Body.String())
	})

	t.Run("share path", func(t *testing.T) {
		tagRequests = nil
		rec := get(url.Values{"s": {"share-id/ignored.mp3"}})
		require.Equal(t, http.StatusOK, rec.Code, rec.Body.String())
		assert.Equal(t, []audiometadata.TagsRequest{{ProviderID: "shared", Path: "/share/file.mp3"}}, tagRequests)
	})

	t.Run("unsupported is 415", func(t *testing.T) {
		rec := get(url.Values{"p": {"/music/other.flac"}})
		assert.Equal(t, http.StatusUnsupportedMediaType, rec.Code)
	})

	t.Run("no parameter is 400", func(t *testing.T) {
		rec := get(url.Values{})
		assert.Equal(t, http.StatusBadRequest, rec.Code)
	})
}

// allowAllAuth lets every `p` request through.
var _ auth.Auth = allowAllAuth{}

type allowAllAuth struct{}

func (allowAllAuth) AuthMiddleware(enablePasswordAuth bool, realm string) func(*gin.Context) bool {
	return func(*gin.Context) bool { return true }
}
func (allowAllAuth) GetUserId(context.Context) string  { return "user" }
func (allowAllAuth) IsSpaceAdmin(context.Context) bool { return false }
