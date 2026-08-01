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
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/spf13/viper"
	"github.com/stretchr/testify/assert"
	"umbasa.net/seraph/api-gateway/auth"
	"umbasa.net/seraph/gallery/gallery"
	"umbasa.net/seraph/logging"
)

var natsServer *server.Server

func TestMain(m *testing.M) {
	gin.SetMode(gin.TestMode)
	setup()
	code := m.Run()
	shutdown()
	os.Exit(code)
}

func setup() {
	opts := &server.Options{}
	var err error
	natsServer, err = server.NewServer(opts)
	if err != nil {
		panic(err)
	}

	natsServer.Start()
	if !natsServer.ReadyForConnections(10 * time.Second) {
		panic("embedded NATS server did not become ready")
	}
}

func shutdown() {
	if natsServer != nil {
		natsServer.Shutdown()
		natsServer = nil
	}
}

func connectNats(t *testing.T) *nats.Conn {
	t.Helper()
	nc, err := nats.Connect(natsServer.ClientURL())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(nc.Close)
	return nc
}

func newGalleryApp(t *testing.T, nc *nats.Conn) *gin.Engine {
	t.Helper()
	logger := logging.New(logging.Params{})
	config := viper.New()
	config.Set("auth.enabled", false)

	authResult, err := auth.New(auth.Params{
		Log:   logger,
		Viper: config,
	})
	if err != nil {
		t.Fatal(err)
	}

	res := New(Params{
		Log:  logger,
		Nc:   nc,
		Auth: authResult.Auth,
	})

	app := gin.New()
	apiGroup := app.Group("/api")
	publicGroup := app.Group("/public")
	res.Handler.Setup(app, apiGroup, publicGroup)
	return app
}

// stubGalleryService answers the gallery CRUD topic, recording the requests it
// received so the test can assert on what the gateway sent.
func stubGalleryService(t *testing.T, nc *nats.Conn, respond func(gallery.GallerySourceFolderCrudRequest) gallery.GallerySourceFolderCrudResponse) *[]gallery.GallerySourceFolderCrudRequest {
	t.Helper()

	received := make([]gallery.GallerySourceFolderCrudRequest, 0)

	sub, err := nc.Subscribe(gallery.GallerySourceFolderCrudTopic, func(msg *nats.Msg) {
		req := gallery.GallerySourceFolderCrudRequest{}
		json.Unmarshal(msg.Data, &req)
		received = append(received, req)

		res := respond(req)
		data, _ := json.Marshal(&res)
		msg.Respond(data)
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		sub.Unsubscribe()
	})

	if err := nc.Flush(); err != nil {
		t.Fatal(err)
	}

	return &received
}

func TestListSourceFoldersUsesAuthenticatedUser(t *testing.T) {
	nc := connectNats(t)
	app := newGalleryApp(t, nc)
	srv := httptest.NewServer(app)
	defer srv.Close()

	received := stubGalleryService(t, nc, func(req gallery.GallerySourceFolderCrudRequest) gallery.GallerySourceFolderCrudResponse {
		return gallery.GallerySourceFolderCrudResponse{
			SourceFolder: []gallery.GallerySourceFolder{},
		}
	})

	resp, err := http.Get(srv.URL + "/api/gallery/source-folders")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	assert.Equal(t, http.StatusOK, resp.StatusCode)
	assert.Equal(t, 1, len(*received))
	assert.Equal(t, gallery.GallerySourceFolderOperationList, (*received)[0].Operation)
	// the user id comes from the authenticated session, never from the client
	assert.Equal(t, "anonymous", (*received)[0].UserId)
}

func TestAddSourceFolderIgnoresClientSuppliedUserId(t *testing.T) {
	nc := connectNats(t)
	app := newGalleryApp(t, nc)
	srv := httptest.NewServer(app)
	defer srv.Close()

	received := stubGalleryService(t, nc, func(req gallery.GallerySourceFolderCrudRequest) gallery.GallerySourceFolderCrudResponse {
		return gallery.GallerySourceFolderCrudResponse{
			SourceFolder: []gallery.GallerySourceFolder{{
				UserId:          req.UserId,
				SpaceProviderId: req.SpaceProviderId,
				Path:            req.Path,
			}},
		}
	})

	body := []byte(`{"spaceProviderId":"photos","path":"/holidays","userId":"someone-else"}`)
	resp, err := http.Post(srv.URL+"/api/gallery/source-folders", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	assert.Equal(t, http.StatusCreated, resp.StatusCode)
	assert.Equal(t, 1, len(*received))
	assert.Equal(t, gallery.GallerySourceFolderOperationAdd, (*received)[0].Operation)
	assert.Equal(t, "photos", (*received)[0].SpaceProviderId)
	assert.Equal(t, "/holidays", (*received)[0].Path)
	// the body's userId must be ignored in favour of the session's
	assert.Equal(t, "anonymous", (*received)[0].UserId)
}

func TestAddSourceFolderValidatesRequest(t *testing.T) {
	nc := connectNats(t)
	app := newGalleryApp(t, nc)
	srv := httptest.NewServer(app)
	defer srv.Close()

	received := stubGalleryService(t, nc, func(req gallery.GallerySourceFolderCrudRequest) gallery.GallerySourceFolderCrudResponse {
		return gallery.GallerySourceFolderCrudResponse{}
	})

	tests := []struct {
		name string
		body string
	}{
		{"missing spaceProviderId", `{"path":"/holidays"}`},
		{"missing path", `{"spaceProviderId":"photos"}`},
		{"relative path", `{"spaceProviderId":"photos","path":"holidays"}`},
		{"malformed json", `{"spaceProviderId":`},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			resp, err := http.Post(srv.URL+"/api/gallery/source-folders", "application/json", bytes.NewReader([]byte(tc.body)))
			if err != nil {
				t.Fatal(err)
			}
			defer resp.Body.Close()

			assert.Equal(t, http.StatusBadRequest, resp.StatusCode)
		})
	}

	// none of the invalid requests reached the gallery service
	assert.Equal(t, 0, len(*received))
}

func TestAddSourceFolderRefusedWithoutAccess(t *testing.T) {
	nc := connectNats(t)
	app := newGalleryApp(t, nc)
	srv := httptest.NewServer(app)
	defer srv.Close()

	stubGalleryService(t, nc, func(req gallery.GallerySourceFolderCrudRequest) gallery.GallerySourceFolderCrudResponse {
		return gallery.GallerySourceFolderCrudResponse{
			Error: "no access to space: photos",
		}
	})

	body := []byte(`{"spaceProviderId":"photos","path":"/holidays"}`)
	resp, err := http.Post(srv.URL+"/api/gallery/source-folders", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	assert.Equal(t, http.StatusForbidden, resp.StatusCode)
}

func TestRemoveSourceFolder(t *testing.T) {
	nc := connectNats(t)
	app := newGalleryApp(t, nc)
	srv := httptest.NewServer(app)
	defer srv.Close()

	received := stubGalleryService(t, nc, func(req gallery.GallerySourceFolderCrudRequest) gallery.GallerySourceFolderCrudResponse {
		if req.Id != "507f1f77bcf86cd799439011" {
			return gallery.GallerySourceFolderCrudResponse{Error: "no such gallery source folder: " + req.Id}
		}
		return gallery.GallerySourceFolderCrudResponse{
			SourceFolder: []gallery.GallerySourceFolder{{}},
		}
	})

	req, err := http.NewRequest(http.MethodDelete, srv.URL+"/api/gallery/source-folders/507f1f77bcf86cd799439011", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	assert.Equal(t, http.StatusOK, resp.StatusCode)
	assert.Equal(t, 1, len(*received))
	assert.Equal(t, gallery.GallerySourceFolderOperationRemove, (*received)[0].Operation)
	assert.Equal(t, "507f1f77bcf86cd799439011", (*received)[0].Id)
	assert.Equal(t, "anonymous", (*received)[0].UserId)

	// a folder that is not the user's is reported as not found
	req, err = http.NewRequest(http.MethodDelete, srv.URL+"/api/gallery/source-folders/507f1f77bcf86cd799439099", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	assert.Equal(t, http.StatusNotFound, resp.StatusCode)
}
