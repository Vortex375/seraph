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
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/nats-io/nats.go"
	"umbasa.net/seraph/gallery-ai/galleryai"
	"umbasa.net/seraph/messaging"
)

// aiRequestTimeout bounds one call to gallery-ai; a search embeds the query
// text, so it is more generous than a plain lookup would need.
const aiRequestTimeout = 15 * time.Second

const errNotFound = "not found"

// startAIApi subscribes the user-scoped fronts of the gallery-ai topics.
func (g *GalleryProvider) startAIApi() error {
	subs := []struct {
		topic   string
		handler func(ctx context.Context, data []byte) any
	}{
		{GallerySearchTopic, func(ctx context.Context, data []byte) any {
			req := GallerySearchRequest{}
			json.Unmarshal(data, &req)
			return g.aiSearch(ctx, &req)
		}},
		{GalleryAnalysisStatusTopic, func(ctx context.Context, data []byte) any {
			req := GalleryAnalysisStatusRequest{}
			json.Unmarshal(data, &req)
			return g.aiStatus(ctx, &req)
		}},
		{GalleryPeopleTopic, func(ctx context.Context, data []byte) any {
			req := GalleryPeopleRequest{}
			json.Unmarshal(data, &req)
			return g.aiPeople(ctx, &req)
		}},
		{GalleryPeopleRenameTopic, func(ctx context.Context, data []byte) any {
			req := GalleryPersonRenameRequest{}
			json.Unmarshal(data, &req)
			return g.aiRename(ctx, &req)
		}},
		{GalleryPhotoAnalysisTopic, func(ctx context.Context, data []byte) any {
			req := GalleryPhotoAnalysisRequest{}
			json.Unmarshal(data, &req)
			return g.aiPhoto(ctx, &req)
		}},
		{GalleryFacesAssignTopic, func(ctx context.Context, data []byte) any {
			req := GalleryFaceAssignRequest{}
			json.Unmarshal(data, &req)
			return g.aiAssign(ctx, &req)
		}},
	}
	for _, s := range subs {
		handler := s.handler
		sub, err := g.nc.QueueSubscribe(s.topic, s.topic, func(msg *nats.Msg) {
			ctx := messaging.ExtractTraceContext(context.Background(), msg)
			ctx, span := g.tracer.Start(ctx, "handle "+msg.Subject)
			defer span.End()

			g.respond(msg, handler(ctx, msg.Data))
		})
		if err != nil {
			return fmt.Errorf("while starting GalleryProvider: %w", err)
		}
		g.aiSubs = append(g.aiSubs, sub)
	}
	return nil
}

func (g *GalleryProvider) stopAIApi() error {
	for _, sub := range g.aiSubs {
		if err := sub.Unsubscribe(); err != nil {
			return fmt.Errorf("while stopping GalleryProvider: %w", err)
		}
	}
	g.aiSubs = nil
	return nil
}

func prefixesOf(folders []resolvedFolder) []galleryai.Prefix {
	prefixes := make([]galleryai.Prefix, 0, len(folders))
	for _, f := range folders {
		prefixes = append(prefixes, galleryai.Prefix{ProviderID: f.providerId, Path: f.path})
	}
	return prefixes
}

// askAI resolves userId's folders, lets prepare fill req from them (it returns
// an error string to refuse) and sends req to gallery-ai. It returns the
// folders for translating the result and, on failure, the error string to
// answer with (including gallery-ai's own res.Error).
func askAI[Req, Res any](ctx context.Context, g *GalleryProvider, userId string, topic string, req *Req, prepare func(*Req, []resolvedFolder) string, res *Res, resError func(*Res) string) ([]resolvedFolder, string) {
	if userId == "" {
		return nil, "userId is required"
	}
	folders, err := g.resolveFoldersForUser(ctx, userId)
	if err != nil {
		return nil, err.Error()
	}
	if e := prepare(req, folders); e != "" {
		return nil, e
	}

	if err := messaging.RequestTimeout(ctx, g.nc, topic, aiRequestTimeout, messaging.Json(req), messaging.Json(res)); err != nil {
		// no responders, timeout or an undecodable answer: gallery-ai is not usable
		g.log.Warn("gallery-ai request failed", "topic", topic, "error", err)
		return nil, ErrorAIUnavailable
	}
	return folders, resError(res)
}

func (g *GalleryProvider) aiSearch(ctx context.Context, req *GallerySearchRequest) *GallerySearchResponse {
	ai := galleryai.SearchRequest{Text: req.Text, Tag: req.Tag, PersonID: req.PersonId, Limit: req.Limit}
	res := galleryai.SearchResponse{}
	folders, errStr := askAI(ctx, g, req.UserId, galleryai.SearchTopic, &ai,
		func(r *galleryai.SearchRequest, f []resolvedFolder) string { r.Prefixes = prefixesOf(f); return "" },
		&res, func(r *galleryai.SearchResponse) string { return r.Error })
	if errStr != "" {
		return &GallerySearchResponse{Error: errStr}
	}
	items := make([]galleryai.SearchItem, 0, len(res.Items))
	for _, it := range res.Items {
		if sp, spath, ok := translate(folders, it.ProviderID, it.Path); ok {
			items = append(items, galleryai.SearchItem{ProviderID: sp, Path: spath, Score: it.Score})
		}
	}
	return &GallerySearchResponse{Items: items}
}

func (g *GalleryProvider) aiStatus(ctx context.Context, req *GalleryAnalysisStatusRequest) *GalleryAnalysisStatusResponse {
	ai := galleryai.StatusRequest{}
	res := galleryai.StatusResponse{}
	_, errStr := askAI(ctx, g, req.UserId, galleryai.StatusTopic, &ai,
		func(r *galleryai.StatusRequest, f []resolvedFolder) string { r.Prefixes = prefixesOf(f); return "" },
		&res, func(r *galleryai.StatusResponse) string { return r.Error })
	if errStr != "" {
		return &GalleryAnalysisStatusResponse{Error: errStr}
	}
	return &GalleryAnalysisStatusResponse{Analysed: res.Analysed, Pending: res.Pending, Failed: res.Failed}
}

// personToSpace translates the cover of p; false when it is outside the folders.
func personToSpace(folders []resolvedFolder, p galleryai.Person) (galleryai.Person, bool) {
	sp, spath, ok := translate(folders, p.Cover.ProviderID, p.Cover.Path)
	p.Cover.ProviderID, p.Cover.Path = sp, spath
	return p, ok
}

func (g *GalleryProvider) aiPeople(ctx context.Context, req *GalleryPeopleRequest) *GalleryPeopleResponse {
	ai := galleryai.PeopleRequest{}
	res := galleryai.PeopleResponse{}
	folders, errStr := askAI(ctx, g, req.UserId, galleryai.PeopleTopic, &ai,
		func(r *galleryai.PeopleRequest, f []resolvedFolder) string { r.Prefixes = prefixesOf(f); return "" },
		&res, func(r *galleryai.PeopleResponse) string { return r.Error })
	if errStr != "" {
		return &GalleryPeopleResponse{Error: errStr}
	}
	people := make([]galleryai.Person, 0, len(res.People))
	for _, p := range res.People {
		if sp, ok := personToSpace(folders, p); ok {
			people = append(people, sp)
		}
	}
	return &GalleryPeopleResponse{People: people}
}

func (g *GalleryProvider) aiRename(ctx context.Context, req *GalleryPersonRenameRequest) *GalleryPersonResponse {
	ai := galleryai.PersonRenameRequest{ID: req.Id, Name: req.Name}
	res := galleryai.PersonResponse{}
	folders, errStr := askAI(ctx, g, req.UserId, galleryai.PersonRenameTopic, &ai,
		func(r *galleryai.PersonRenameRequest, f []resolvedFolder) string {
			r.Prefixes = prefixesOf(f)
			return ""
		},
		&res, func(r *galleryai.PersonResponse) string { return r.Error })
	if errStr != "" {
		return &GalleryPersonResponse{Error: errStr}
	}
	if res.Person == nil {
		return &GalleryPersonResponse{Error: errNotFound}
	}
	p, ok := personToSpace(folders, *res.Person)
	if !ok {
		return &GalleryPersonResponse{Error: errNotFound}
	}
	return &GalleryPersonResponse{Person: &p}
}

func (g *GalleryProvider) aiPhoto(ctx context.Context, req *GalleryPhotoAnalysisRequest) *GalleryPhotoAnalysisResponse {
	ai := galleryai.PhotoRequest{}
	res := galleryai.PhotoResponse{}
	_, errStr := askAI(ctx, g, req.UserId, galleryai.PhotoTopic, &ai,
		func(r *galleryai.PhotoRequest, f []resolvedFolder) string {
			pid, p, ok := toPhysical(f, req.ProviderId, req.Path)
			if !ok {
				return errNotFound
			}
			r.Prefixes, r.ProviderID, r.Path = prefixesOf(f), pid, p
			return ""
		},
		&res, func(r *galleryai.PhotoResponse) string { return r.Error })
	if errStr != "" {
		return &GalleryPhotoAnalysisResponse{Error: errStr}
	}
	return &GalleryPhotoAnalysisResponse{Analysed: res.Analysed, AnalysisError: res.AnalysisError, Tags: res.Tags, Faces: res.Faces}
}

func (g *GalleryProvider) aiAssign(ctx context.Context, req *GalleryFaceAssignRequest) *GalleryFaceResponse {
	ai := galleryai.FaceAssignRequest{FaceID: req.FaceId, PersonID: req.PersonId, NewPersonName: req.NewPersonName, Unassign: req.Unassign}
	res := galleryai.FaceResponse{}
	_, errStr := askAI(ctx, g, req.UserId, galleryai.FaceAssignTopic, &ai,
		func(r *galleryai.FaceAssignRequest, f []resolvedFolder) string { r.Prefixes = prefixesOf(f); return "" },
		&res, func(r *galleryai.FaceResponse) string { return r.Error })
	if errStr != "" {
		return &GalleryFaceResponse{Error: errStr}
	}
	return &GalleryFaceResponse{Face: res.Face}
}
