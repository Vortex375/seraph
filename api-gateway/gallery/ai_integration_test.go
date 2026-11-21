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
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"umbasa.net/seraph/gallery/gallery"
)

// stubTopic answers a gallery topic with a fixed response, recording the raw requests.
func stubTopic(t *testing.T, nc *nats.Conn, topic string, response any) *[][]byte {
	t.Helper()
	received := make([][]byte, 0)
	sub, err := nc.Subscribe(topic, func(msg *nats.Msg) {
		received = append(received, msg.Data)
		data, _ := json.Marshal(response)
		msg.Respond(data)
	})
	require.NoError(t, err)
	t.Cleanup(func() { sub.Unsubscribe() })
	require.NoError(t, nc.Flush())
	return &received
}

func do(t *testing.T, method, url, body string) (int, string) {
	t.Helper()
	req, err := http.NewRequest(method, url, strings.NewReader(body))
	require.NoError(t, err)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(data)
}

func TestSearchPassesParametersAndUser(t *testing.T) {
	nc := connectNats(t)
	srv := httptest.NewServer(newGalleryApp(t, nc))
	defer srv.Close()
	received := stubTopic(t, nc, gallery.GallerySearchTopic, gallery.GallerySearchResponse{})

	code, _ := do(t, "GET", srv.URL+"/api/gallery/search?q=beach&tag=sea&person=p1&limit=7", "")
	assert.Equal(t, http.StatusOK, code)
	require.Len(t, *received, 1)
	req := gallery.GallerySearchRequest{}
	require.NoError(t, json.Unmarshal((*received)[0], &req))
	assert.Equal(t, gallery.GallerySearchRequest{UserId: "anonymous", Text: "beach", Tag: "sea", PersonId: "p1", Limit: 7}, req)

	code, _ = do(t, "GET", srv.URL+"/api/gallery/search?limit=x", "")
	assert.Equal(t, http.StatusBadRequest, code)
	assert.Len(t, *received, 1)
}

func TestAIStatusMapping(t *testing.T) {
	cases := []struct {
		err  string
		code int
	}{
		{gallery.ErrorAIUnavailable, http.StatusServiceUnavailable},
		{"not found", http.StatusNotFound},
		{"boom", http.StatusInternalServerError},
	}
	for _, c := range cases {
		t.Run(c.err, func(t *testing.T) {
			nc := connectNats(t)
			srv := httptest.NewServer(newGalleryApp(t, nc))
			defer srv.Close()
			stubTopic(t, nc, gallery.GalleryPeopleTopic, gallery.GalleryPeopleResponse{Error: c.err})

			code, body := do(t, "GET", srv.URL+"/api/gallery/people", "")
			assert.Equal(t, c.code, code)
			if c.err == gallery.ErrorAIUnavailable {
				assert.JSONEq(t, `{"error":"ai-unavailable"}`, body)
			}
		})
	}
}

func TestPeopleRenameAndStatusAndPhotoRoutes(t *testing.T) {
	nc := connectNats(t)
	srv := httptest.NewServer(newGalleryApp(t, nc))
	defer srv.Close()

	rename := stubTopic(t, nc, gallery.GalleryPeopleRenameTopic, gallery.GalleryPersonResponse{})
	stubTopic(t, nc, gallery.GalleryAnalysisStatusTopic, gallery.GalleryAnalysisStatusResponse{Analysed: 1, Pending: 2, Failed: 3, Tags: []string{"pet"}})
	photo := stubTopic(t, nc, gallery.GalleryPhotoAnalysisTopic, gallery.GalleryPhotoAnalysisResponse{Analysed: true})

	code, _ := do(t, "PATCH", srv.URL+"/api/gallery/people/p1", `{"name":"Ann"}`)
	assert.Equal(t, http.StatusOK, code)
	req := gallery.GalleryPersonRenameRequest{}
	require.NoError(t, json.Unmarshal((*rename)[0], &req))
	assert.Equal(t, gallery.GalleryPersonRenameRequest{UserId: "anonymous", Id: "p1", Name: "Ann"}, req)

	code, _ = do(t, "PATCH", srv.URL+"/api/gallery/people/p1", `{}`)
	assert.Equal(t, http.StatusBadRequest, code)
	assert.Len(t, *rename, 1)

	code, body := do(t, "GET", srv.URL+"/api/gallery/analysis/status", "")
	assert.Equal(t, http.StatusOK, code)
	assert.JSONEq(t, `{"error":"","analysed":1,"pending":2,"failed":3,"tags":["pet"]}`, body)

	code, _ = do(t, "GET", srv.URL+"/api/gallery/photos/analysis?providerId=photos&path=/a/b.jpg", "")
	assert.Equal(t, http.StatusOK, code)
	preq := gallery.GalleryPhotoAnalysisRequest{}
	require.NoError(t, json.Unmarshal((*photo)[0], &preq))
	assert.Equal(t, gallery.GalleryPhotoAnalysisRequest{UserId: "anonymous", ProviderId: "photos", Path: "/a/b.jpg"}, preq)

	code, _ = do(t, "GET", srv.URL+"/api/gallery/photos/analysis?providerId=photos", "")
	assert.Equal(t, http.StatusBadRequest, code)
	assert.Len(t, *photo, 1)
}

func TestFaceAssignBodyValidation(t *testing.T) {
	nc := connectNats(t)
	srv := httptest.NewServer(newGalleryApp(t, nc))
	defer srv.Close()
	received := stubTopic(t, nc, gallery.GalleryFacesAssignTopic, gallery.GalleryFaceResponse{})

	url := srv.URL + "/api/gallery/faces/f1/person"
	for _, body := range []string{
		`{}`, // none
		`{"personId":"p1","newPersonName":"Ann"}`, // two
		`{"personId":null,"newPersonName":"Ann"}`, // two
		`{"personId":""}`,                         // empty
		`{"newPersonName":null}`,                  // null name is not unassign
		`{"newPersonName":""}`,                    // empty name
		`{"personId":5}`,                          // wrong type
		`not json`,
	} {
		code, _ := do(t, "PUT", url, body)
		assert.Equal(t, http.StatusBadRequest, code, body)
	}
	assert.Empty(t, *received)

	cases := []struct {
		body string
		want gallery.GalleryFaceAssignRequest
	}{
		{`{"personId":"p1"}`, gallery.GalleryFaceAssignRequest{UserId: "anonymous", FaceId: "f1", PersonId: "p1"}},
		{`{"newPersonName":"Ann"}`, gallery.GalleryFaceAssignRequest{UserId: "anonymous", FaceId: "f1", NewPersonName: "Ann"}},
		{`{"personId":null}`, gallery.GalleryFaceAssignRequest{UserId: "anonymous", FaceId: "f1", Unassign: true}},
	}
	for i, c := range cases {
		code, _ := do(t, "PUT", url, c.body)
		assert.Equal(t, http.StatusOK, code, c.body)
		require.Len(t, *received, i+1)
		got := gallery.GalleryFaceAssignRequest{}
		require.NoError(t, json.Unmarshal((*received)[i], &got))
		assert.Equal(t, c.want, got, c.body)
	}
}
