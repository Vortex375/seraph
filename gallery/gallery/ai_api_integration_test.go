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

package gallery_test

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"umbasa.net/seraph/gallery-ai/galleryai"
	"umbasa.net/seraph/gallery/gallery"
	"umbasa.net/seraph/messaging"
)

// fakeAI answers a gallery-ai topic and records the requests it received.
func fakeAI[Req any](t *testing.T, nc *nats.Conn, topic string, respond func(Req) any) *[]Req {
	t.Helper()
	received := make([]Req, 0)
	sub, err := nc.Subscribe(topic, func(msg *nats.Msg) {
		req := *new(Req)
		json.Unmarshal(msg.Data, &req)
		received = append(received, req)
		data, _ := json.Marshal(respond(req))
		msg.Respond(data)
	})
	require.NoError(t, err)
	t.Cleanup(func() { sub.Unsubscribe() })
	require.NoError(t, nc.Flush())
	return &received
}

func ask[Req, Res any](t *testing.T, nc *nats.Conn, topic string, req Req) Res {
	t.Helper()
	res := *new(Res)
	require.NoError(t, messaging.Request(context.Background(), nc, topic, messaging.Json(&req), messaging.Json(&res)))
	return res
}

func setupAIUser(t *testing.T) *nats.Conn {
	t.Helper()
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos", "docs"},
		"anna": {"other"},
	})
	clearSourceFolders(t, db)
	for _, f := range []struct{ user, space, path string }{
		{"pino", "photos", "/holidays"},
		{"pino", "docs", "/"},
		{"anna", "other", "/private"},
	} {
		res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
			Operation: gallery.GallerySourceFolderOperationAdd, UserId: f.user, SpaceProviderId: f.space, Path: f.path,
		})
		require.Equal(t, "", res.Error)
	}
	return nc
}

var pinoPrefixes = []galleryai.Prefix{
	{ProviderID: "physical-photos", Path: "/mounted/photos/holidays"},
	{ProviderID: "physical-docs", Path: "/mounted/docs"},
}

func TestAISearchIsScopedAndTranslated(t *testing.T) {
	requireIntegration(t)
	nc := setupAIUser(t)

	received := fakeAI(t, nc, galleryai.SearchTopic, func(galleryai.SearchRequest) any {
		return galleryai.SearchResponse{Items: []galleryai.SearchItem{
			{ProviderID: "physical-photos", Path: "/mounted/photos/holidays/sub/a.jpg", Score: 0.9},
			{ProviderID: "physical-photos", Path: "/mounted/photos/elsewhere/b.jpg", Score: 0.8}, // outside: dropped
			{ProviderID: "physical-other", Path: "/mounted/other/private/c.jpg", Score: 0.7},     // another user's: dropped
			{ProviderID: "physical-docs", Path: "/mounted/docs/d.jpg", Score: 0.6},
		}}
	})

	res := ask[gallery.GallerySearchRequest, gallery.GallerySearchResponse](t, nc, gallery.GallerySearchTopic,
		gallery.GallerySearchRequest{UserId: "pino", Text: "beach", Tag: "sea", PersonId: "p1", Limit: 5})

	assert.Equal(t, "", res.Error)
	require.Len(t, *received, 1)
	assert.ElementsMatch(t, pinoPrefixes, (*received)[0].Prefixes)
	assert.Equal(t, "beach", (*received)[0].Text)
	assert.Equal(t, "sea", (*received)[0].Tag)
	assert.Equal(t, "p1", (*received)[0].PersonID)
	assert.Equal(t, 5, (*received)[0].Limit)
	assert.Equal(t, []galleryai.SearchItem{
		{ProviderID: "photos", Path: "/holidays/sub/a.jpg", Score: 0.9},
		{ProviderID: "docs", Path: "/d.jpg", Score: 0.6},
	}, res.Items)

	// anna only ever sees her own folder's prefix
	ask[gallery.GallerySearchRequest, gallery.GallerySearchResponse](t, nc, gallery.GallerySearchTopic, gallery.GallerySearchRequest{UserId: "anna"})
	require.Len(t, *received, 2)
	assert.Equal(t, []galleryai.Prefix{{ProviderID: "physical-other", Path: "/mounted/other/private"}}, (*received)[1].Prefixes)
}

func TestAIStatusAndAssignPassThrough(t *testing.T) {
	requireIntegration(t)
	nc := setupAIUser(t)

	status := fakeAI(t, nc, galleryai.StatusTopic, func(galleryai.StatusRequest) any {
		return galleryai.StatusResponse{Analysed: 3, Pending: 2, Failed: 1, Tags: []string{"pet"}}
	})
	st := ask[gallery.GalleryAnalysisStatusRequest, gallery.GalleryAnalysisStatusResponse](t, nc, gallery.GalleryAnalysisStatusTopic,
		gallery.GalleryAnalysisStatusRequest{UserId: "pino"})
	assert.Equal(t, gallery.GalleryAnalysisStatusResponse{Analysed: 3, Pending: 2, Failed: 1, Tags: []string{"pet"}}, st)
	assert.ElementsMatch(t, pinoPrefixes, (*status)[0].Prefixes)

	assign := fakeAI(t, nc, galleryai.FaceAssignTopic, func(r galleryai.FaceAssignRequest) any {
		if r.FaceID == "missing" {
			return galleryai.FaceResponse{Error: "not found"}
		}
		return galleryai.FaceResponse{Face: &galleryai.PhotoFace{ID: r.FaceID, PersonID: r.PersonID, Manual: true}}
	})
	res := ask[gallery.GalleryFaceAssignRequest, gallery.GalleryFaceResponse](t, nc, gallery.GalleryFacesAssignTopic,
		gallery.GalleryFaceAssignRequest{UserId: "pino", FaceId: "f1", PersonId: "p1"})
	require.NotNil(t, res.Face)
	assert.Equal(t, "p1", res.Face.PersonID)
	assert.ElementsMatch(t, pinoPrefixes, (*assign)[0].Prefixes)
	assert.Equal(t, "f1", (*assign)[0].FaceID)

	res = ask[gallery.GalleryFaceAssignRequest, gallery.GalleryFaceResponse](t, nc, gallery.GalleryFacesAssignTopic,
		gallery.GalleryFaceAssignRequest{UserId: "pino", FaceId: "missing", Unassign: true})
	assert.Equal(t, "not found", res.Error)
	assert.True(t, (*assign)[1].Unassign)
}

func TestAIPeopleCoversAreTranslated(t *testing.T) {
	requireIntegration(t)
	nc := setupAIUser(t)

	rename := fakeAI(t, nc, galleryai.PersonRenameTopic, func(r galleryai.PersonRenameRequest) any {
		if r.ID == "gone" {
			return galleryai.PersonResponse{Error: "not found"}
		}
		return galleryai.PersonResponse{Person: &galleryai.Person{ID: r.ID, Name: r.Name, PhotoCount: 2,
			Cover: galleryai.Cover{ProviderID: "physical-photos", Path: "/mounted/photos/holidays/a.jpg"}}}
	})
	fakeAI(t, nc, galleryai.PeopleTopic, func(galleryai.PeopleRequest) any {
		return galleryai.PeopleResponse{People: []galleryai.Person{
			{ID: "1", Name: "Ann", PhotoCount: 4, Cover: galleryai.Cover{ProviderID: "physical-photos", Path: "/mounted/photos/holidays/a.jpg", Box: galleryai.Box{X1: 0.1, Y1: 0.2, X2: 0.3, Y2: 0.4}}},
			{ID: "2", Cover: galleryai.Cover{ProviderID: "physical-other", Path: "/mounted/other/private/x.jpg"}}, // not translatable: dropped
		}}
	})

	people := ask[gallery.GalleryPeopleRequest, gallery.GalleryPeopleResponse](t, nc, gallery.GalleryPeopleTopic, gallery.GalleryPeopleRequest{UserId: "pino"})
	assert.Equal(t, "", people.Error)
	require.Len(t, people.People, 1)
	assert.Equal(t, "1", people.People[0].ID)
	assert.Equal(t, galleryai.Cover{ProviderID: "photos", Path: "/holidays/a.jpg", Box: galleryai.Box{X1: 0.1, Y1: 0.2, X2: 0.3, Y2: 0.4}}, people.People[0].Cover)

	res := ask[gallery.GalleryPersonRenameRequest, gallery.GalleryPersonResponse](t, nc, gallery.GalleryPeopleRenameTopic,
		gallery.GalleryPersonRenameRequest{UserId: "pino", Id: "1", Name: "Anna"})
	require.NotNil(t, res.Person)
	assert.Equal(t, "Anna", res.Person.Name)
	assert.Equal(t, "/holidays/a.jpg", res.Person.Cover.Path)
	assert.ElementsMatch(t, pinoPrefixes, (*rename)[0].Prefixes)

	res = ask[gallery.GalleryPersonRenameRequest, gallery.GalleryPersonResponse](t, nc, gallery.GalleryPeopleRenameTopic,
		gallery.GalleryPersonRenameRequest{UserId: "pino", Id: "gone"})
	assert.Equal(t, "not found", res.Error)
	assert.Nil(t, res.Person)
}

func TestAIPhotoAnalysisTranslatesInput(t *testing.T) {
	requireIntegration(t)
	nc := setupAIUser(t)

	received := fakeAI(t, nc, galleryai.PhotoTopic, func(galleryai.PhotoRequest) any {
		return galleryai.PhotoResponse{Analysed: true, Tags: []galleryai.PhotoTag{{Tag: "beach", Score: 0.5}},
			Faces: []galleryai.PhotoFace{{ID: "f1", PersonID: "p1", PersonName: "Ann"}}}
	})

	res := ask[gallery.GalleryPhotoAnalysisRequest, gallery.GalleryPhotoAnalysisResponse](t, nc, gallery.GalleryPhotoAnalysisTopic,
		gallery.GalleryPhotoAnalysisRequest{UserId: "pino", ProviderId: "photos", Path: "/holidays/sub/a.jpg"})
	assert.Equal(t, "", res.Error)
	assert.True(t, res.Analysed)
	require.Len(t, res.Tags, 1)
	require.Len(t, res.Faces, 1)
	require.Len(t, *received, 1)
	assert.Equal(t, "physical-photos", (*received)[0].ProviderID)
	assert.Equal(t, "/mounted/photos/holidays/sub/a.jpg", (*received)[0].Path)
	assert.ElementsMatch(t, pinoPrefixes, (*received)[0].Prefixes)

	// outside the user's folders (or another user's Space): refused without asking gallery-ai
	for _, p := range [][2]string{{"photos", "/elsewhere/a.jpg"}, {"other", "/private/c.jpg"}} {
		res = ask[gallery.GalleryPhotoAnalysisRequest, gallery.GalleryPhotoAnalysisResponse](t, nc, gallery.GalleryPhotoAnalysisTopic,
			gallery.GalleryPhotoAnalysisRequest{UserId: "pino", ProviderId: p[0], Path: p[1]})
		assert.Equal(t, "not found", res.Error)
	}
	assert.Len(t, *received, 1)
}

func TestAIUnavailableWithoutResponder(t *testing.T) {
	requireIntegration(t)
	nc := setupAIUser(t)

	assert.Equal(t, gallery.ErrorAIUnavailable, ask[gallery.GallerySearchRequest, gallery.GallerySearchResponse](t, nc, gallery.GallerySearchTopic, gallery.GallerySearchRequest{UserId: "pino"}).Error)
	assert.Equal(t, gallery.ErrorAIUnavailable, ask[gallery.GalleryAnalysisStatusRequest, gallery.GalleryAnalysisStatusResponse](t, nc, gallery.GalleryAnalysisStatusTopic, gallery.GalleryAnalysisStatusRequest{UserId: "pino"}).Error)
	assert.Equal(t, gallery.ErrorAIUnavailable, ask[gallery.GalleryPeopleRequest, gallery.GalleryPeopleResponse](t, nc, gallery.GalleryPeopleTopic, gallery.GalleryPeopleRequest{UserId: "pino"}).Error)
	assert.Equal(t, gallery.ErrorAIUnavailable, ask[gallery.GalleryPersonRenameRequest, gallery.GalleryPersonResponse](t, nc, gallery.GalleryPeopleRenameTopic, gallery.GalleryPersonRenameRequest{UserId: "pino", Id: "1"}).Error)
	assert.Equal(t, gallery.ErrorAIUnavailable, ask[gallery.GalleryPhotoAnalysisRequest, gallery.GalleryPhotoAnalysisResponse](t, nc, gallery.GalleryPhotoAnalysisTopic, gallery.GalleryPhotoAnalysisRequest{UserId: "pino", ProviderId: "photos", Path: "/holidays/a.jpg"}).Error)
	assert.Equal(t, gallery.ErrorAIUnavailable, ask[gallery.GalleryFaceAssignRequest, gallery.GalleryFaceResponse](t, nc, gallery.GalleryFacesAssignTopic, gallery.GalleryFaceAssignRequest{UserId: "pino", FaceId: "f", Unassign: true}).Error)
}
