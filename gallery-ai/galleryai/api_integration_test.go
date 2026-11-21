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

package galleryai_test

import (
	"context"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"umbasa.net/seraph/gallery-ai/galleryai"
	"umbasa.net/seraph/messaging"
)

func call[Res any](t *testing.T, e *env, topic string, req any) Res {
	t.Helper()
	var res Res
	require.NoError(t, messaging.Request(context.Background(), e.nc, topic, messaging.Json(req), messaging.Json(&res)))
	return res
}

func pfx(provider string, paths ...string) []galleryai.Prefix {
	var out []galleryai.Prefix
	for _, p := range paths {
		out = append(out, galleryai.Prefix{ProviderID: provider, Path: p})
	}
	return out
}

// seedPhoto inserts a live photo with an image embedding at deg degrees (see ang) and the given tags.
func (e *env) seedPhoto(t *testing.T, provider, path string, seq int64, deg float64, tags ...string) {
	ctx := context.Background()
	// the startup re-tag pass rewrites photo_tags; let it finish before seeding tags
	require.Eventually(t, func() bool {
		var h string
		return e.pool.QueryRow(ctx, `SELECT config_hash FROM tag_state`).Scan(&h) == nil && h != ""
	}, 10*time.Second, 20*time.Millisecond)
	_, err := e.pool.Exec(ctx, `INSERT INTO photos (provider_id, path, seq, model, analysed_at) VALUES ($1, $2, $3, 'clip-test', now())`, provider, path, seq)
	require.NoError(t, err)
	_, err = e.pool.Exec(ctx, `INSERT INTO photo_embeddings (provider_id, path, embedding) VALUES ($1, $2, $3::text::vector)`, provider, path, ang(deg))
	require.NoError(t, err)
	for _, tag := range tags {
		_, err = e.pool.Exec(ctx, `INSERT INTO photo_tags (provider_id, path, tag, score) VALUES ($1, $2, $3, 0.5)`, provider, path, tag)
		require.NoError(t, err)
	}
}

// seedPersonFace adds a face of person (may be "") on a photo of provider "p" with the given score.
func (e *env) seedPersonFace(t *testing.T, path string, person string, score float64) string {
	ctx := context.Background()
	_, err := e.pool.Exec(ctx, `INSERT INTO photos (provider_id, path, seq, model) VALUES ('p', $1, 1, 'clip-test') ON CONFLICT DO NOTHING`, path)
	require.NoError(t, err)
	var id string
	require.NoError(t, e.pool.QueryRow(ctx, `
		INSERT INTO faces (provider_id, path, box_x1, box_y1, box_x2, box_y2, score, person_id, clustered, embedding)
		VALUES ('p', $1, 0.1, 0.2, 0.3, 0.4, $2, NULLIF($3, '')::uuid, true, $4::text::vector) RETURNING id::text`, path, score, person, ang(0)).Scan(&id))
	return id
}

func (e *env) newPerson(t *testing.T, name string) string {
	var id string
	require.NoError(t, e.pool.QueryRow(context.Background(), `INSERT INTO persons (name) VALUES (NULLIF($1, '')) RETURNING id::text`, name).Scan(&id))
	return id
}

func (e *env) setCover(t *testing.T, person, face string) {
	_, err := e.pool.Exec(context.Background(), `UPDATE persons SET cover_face_id = $2 WHERE id = $1`, person, face)
	require.NoError(t, err)
}

func paths(items []galleryai.SearchItem) []string {
	out := []string{}
	for _, i := range items {
		out = append(out, i.ProviderID+":"+i.Path)
	}
	return out
}

func TestSearchPrefixScoping(t *testing.T) {
	e := start(t)
	for i, p := range []string{"/a%/1.jpg", "/abc/2.jpg", "/a_c/3.jpg", "/axc/4.jpg", "/a/5.jpg", "/ab/6.jpg", "/a%x/7.jpg"} {
		e.seedPhoto(t, "p", p, int64(i+1), 0)
	}
	e.seedPhoto(t, "q", "/a/other.jpg", 10, 0)
	search := func(prefixes []galleryai.Prefix) []string {
		return paths(call[galleryai.SearchResponse](t, e, galleryai.SearchTopic, galleryai.SearchRequest{Prefixes: prefixes}).Items)
	}

	assert.Equal(t, []string{"p:/a%/1.jpg"}, search(pfx("p", "/a%")))
	assert.Equal(t, []string{"p:/a_c/3.jpg"}, search(pfx("p", "/a_c")))
	assert.Equal(t, []string{"p:/a/5.jpg"}, search(pfx("p", "/a/")))
	assert.Len(t, search(pfx("p", "/")), 7)
	assert.Contains(t, search(pfx("q", "/")), "q:/a/other.jpg")
	assert.Equal(t, []string{"p:/a/5.jpg", "p:/abc/2.jpg"}, search(pfx("p", "/a", "/abc")))
	assert.Empty(t, search(nil))
	assert.Empty(t, search(pfx("nope", "/")))
	// newest seq first without text
	assert.Equal(t, []string{"p:/a%x/7.jpg", "p:/ab/6.jpg"}, search(pfx("p", "/a%x", "/ab")))

	// deleted photos never appear
	_, err := e.pool.Exec(context.Background(), `UPDATE photos SET deleted = true WHERE path = '/a/5.jpg'`)
	require.NoError(t, err)
	assert.Empty(t, search(pfx("p", "/a")))
}

func TestSearchTextRankingFiltersAndLimit(t *testing.T) {
	e := start(t)
	e.seedPhoto(t, "p", "/far.jpg", 1, 80, "dog")
	e.seedPhoto(t, "p", "/near.jpg", 2, 5, "dog", "cat")
	e.seedPhoto(t, "p", "/mid.jpg", 3, 40, "cat")
	e.seedPhoto(t, "p", "/out/near.jpg", 4, 0, "dog")
	alice := e.newPerson(t, "Alice")
	e.seedPersonFace(t, "/near.jpg", alice, 0.9)
	e.seedPersonFace(t, "/far.jpg", alice, 0.9)

	req := galleryai.SearchRequest{Prefixes: pfx("p", "/far.jpg", "/near.jpg", "/mid.jpg"), Text: "match"}
	res := call[galleryai.SearchResponse](t, e, galleryai.SearchTopic, req)
	require.Empty(t, res.Error)
	assert.Equal(t, []string{"p:/near.jpg", "p:/mid.jpg", "p:/far.jpg"}, paths(res.Items))
	assert.InDelta(t, 1-(1-0.9962), res.Items[0].Score, 0.001) // cos(5 deg)
	assert.Greater(t, res.Items[0].Score, res.Items[1].Score)

	req.Tag = "dog"
	assert.Equal(t, []string{"p:/near.jpg", "p:/far.jpg"}, paths(call[galleryai.SearchResponse](t, e, galleryai.SearchTopic, req).Items))
	req.PersonID = alice
	assert.Equal(t, []string{"p:/near.jpg", "p:/far.jpg"}, paths(call[galleryai.SearchResponse](t, e, galleryai.SearchTopic, req).Items))
	req.Tag = "cat"
	assert.Equal(t, []string{"p:/near.jpg"}, paths(call[galleryai.SearchResponse](t, e, galleryai.SearchTopic, req).Items))

	// person filter without text: newest first, score 0
	res = call[galleryai.SearchResponse](t, e, galleryai.SearchTopic, galleryai.SearchRequest{Prefixes: pfx("p", "/"), PersonID: alice})
	assert.Equal(t, []string{"p:/near.jpg", "p:/far.jpg"}, paths(res.Items))
	assert.Zero(t, res.Items[0].Score)

	req = galleryai.SearchRequest{Prefixes: pfx("p", "/"), Limit: 2}
	assert.Len(t, call[galleryai.SearchResponse](t, e, galleryai.SearchTopic, req).Items, 2)
}

func TestSearchLimitCap(t *testing.T) {
	e := start(t)
	_, err := e.pool.Exec(context.Background(), `INSERT INTO photos (provider_id, path, seq) SELECT 'p', '/' || g, g FROM generate_series(1, 1100) g`)
	require.NoError(t, err)
	assert.Len(t, call[galleryai.SearchResponse](t, e, galleryai.SearchTopic, galleryai.SearchRequest{Prefixes: pfx("p", "/"), Limit: 5000}).Items, galleryai.MaxSearchLimit)
	assert.Len(t, call[galleryai.SearchResponse](t, e, galleryai.SearchTopic, galleryai.SearchRequest{Prefixes: pfx("p", "/")}).Items, galleryai.DefaultSearchLimit)
}

func TestSearchTextWithMLDownIsError(t *testing.T) {
	e := start(t)
	e.ml.textStatus.Store(503)
	res := call[galleryai.SearchResponse](t, e, galleryai.SearchTopic, galleryai.SearchRequest{Prefixes: pfx("p", "/"), Text: "match"})
	assert.NotEmpty(t, res.Error)
}

func TestStatusCountsWithinPrefixes(t *testing.T) {
	e := start(t)
	e.seedPhoto(t, "p", "/in/done.jpg", 1, 0)
	e.seedPhoto(t, "p", "/out/done.jpg", 1, 0)
	ctx := context.Background()
	_, err := e.pool.Exec(ctx, `INSERT INTO photos (provider_id, path, seq) VALUES ('p', '/in/pending.jpg', 1)`)
	require.NoError(t, err)
	_, err = e.pool.Exec(ctx, `INSERT INTO photos (provider_id, path, seq, error) VALUES ('p', '/in/bad.jpg', 1, 'unsupported'), ('p', '/in/bad2.jpg', 1, 'x')`)
	require.NoError(t, err)
	_, err = e.pool.Exec(ctx, `INSERT INTO photos (provider_id, path, seq, deleted) VALUES ('p', '/in/gone.jpg', 2, true)`)
	require.NoError(t, err)

	res := call[galleryai.StatusResponse](t, e, galleryai.StatusTopic, galleryai.StatusRequest{Prefixes: pfx("p", "/in")})
	assert.Equal(t, galleryai.StatusResponse{Analysed: 1, Pending: 1, Failed: 2}, res)
	res = call[galleryai.StatusResponse](t, e, galleryai.StatusTopic, galleryai.StatusRequest{})
	assert.Equal(t, galleryai.StatusResponse{}, res)
}

func TestPeopleVisibilityCountCoverAndRename(t *testing.T) {
	e := start(t)
	alice := e.newPerson(t, "Alice")
	bob := e.newPerson(t, "")
	carol := e.newPerson(t, "")
	hidden := e.newPerson(t, "Hidden")
	// alice: cover is in an invisible photo; two visible photos (one with two faces)
	cover := e.seedPersonFace(t, "/out/a.jpg", alice, 0.99)
	e.setCover(t, alice, cover)
	a1 := e.seedPersonFace(t, "/in/a1.jpg", alice, 0.5)
	e.seedPersonFace(t, "/in/a2.jpg", alice, 0.8)
	e.seedPersonFace(t, "/in/a2.jpg", alice, 0.6)
	// bob: unnamed, three visible photos; carol: unnamed, one
	for _, p := range []string{"/in/b1.jpg", "/in/b2.jpg", "/in/b3.jpg"} {
		e.seedPersonFace(t, p, bob, 0.9)
	}
	e.seedPersonFace(t, "/in/c.jpg", carol, 0.9)
	e.seedPersonFace(t, "/out/h.jpg", hidden, 0.9)

	req := galleryai.PeopleRequest{Prefixes: pfx("p", "/in")}
	res := call[galleryai.PeopleResponse](t, e, galleryai.PeopleTopic, req)
	require.Empty(t, res.Error)
	require.Len(t, res.People, 3)
	assert.Equal(t, alice, res.People[0].ID) // named first
	assert.Equal(t, "Alice", res.People[0].Name)
	assert.Equal(t, 2, res.People[0].PhotoCount)
	assert.Equal(t, "/in/a2.jpg", res.People[0].Cover.Path)
	assert.Equal(t, "p", res.People[0].Cover.ProviderID)
	assert.Equal(t, galleryai.Box{X1: 0.1, Y1: 0.2, X2: 0.3, Y2: 0.4}, res.People[0].Cover.Box)
	assert.Equal(t, []string{bob, carol}, []string{res.People[1].ID, res.People[2].ID})
	assert.Equal(t, 3, res.People[1].PhotoCount)

	// visible cover face is used
	e.setCover(t, alice, a1)
	res = call[galleryai.PeopleResponse](t, e, galleryai.PeopleTopic, req)
	assert.Equal(t, "/in/a1.jpg", res.People[0].Cover.Path)
	res = call[galleryai.PeopleResponse](t, e, galleryai.PeopleTopic, galleryai.PeopleRequest{Prefixes: pfx("p", "/")})
	assert.Len(t, res.People, 4)

	// rename: visible works, invisible does not
	ren := call[galleryai.PersonResponse](t, e, galleryai.PersonRenameTopic, galleryai.PersonRenameRequest{Prefixes: pfx("p", "/in"), ID: bob, Name: "Bob"})
	require.Empty(t, ren.Error)
	assert.Equal(t, "Bob", ren.Person.Name)
	assert.Equal(t, 3, ren.Person.PhotoCount)
	ren = call[galleryai.PersonResponse](t, e, galleryai.PersonRenameTopic, galleryai.PersonRenameRequest{Prefixes: pfx("p", "/in"), ID: hidden, Name: "X"})
	assert.Equal(t, "not found", ren.Error)
	var name *string
	require.NoError(t, e.pool.QueryRow(context.Background(), `SELECT name FROM persons WHERE id = $1`, hidden).Scan(&name))
	assert.Equal(t, "Hidden", *name)

	// empty name makes the person unnamed (NULL)
	ren = call[galleryai.PersonResponse](t, e, galleryai.PersonRenameTopic, galleryai.PersonRenameRequest{Prefixes: pfx("p", "/in"), ID: alice})
	require.Empty(t, ren.Error)
	require.NoError(t, e.pool.QueryRow(context.Background(), `SELECT name FROM persons WHERE id = $1`, alice).Scan(&name))
	assert.Nil(t, name)
}

func TestPhotoAnalysis(t *testing.T) {
	e := start(t)
	e.seedPhoto(t, "p", "/in/a.jpg", 1, 0, "dog")
	alice := e.newPerson(t, "Alice")
	face := e.seedPersonFace(t, "/in/a.jpg", alice, 0.9)
	_, err := e.pool.Exec(context.Background(), `INSERT INTO photos (provider_id, path, seq) VALUES ('p', '/in/new.jpg', 1)`)
	require.NoError(t, err)
	_, err = e.pool.Exec(context.Background(), `INSERT INTO photos (provider_id, path, seq, error) VALUES ('p', '/in/bad.jpg', 1, 'unsupported')`)
	require.NoError(t, err)
	get := func(prefix, path string) galleryai.PhotoResponse {
		return call[galleryai.PhotoResponse](t, e, galleryai.PhotoTopic, galleryai.PhotoRequest{Prefixes: pfx("p", prefix), ProviderID: "p", Path: path})
	}

	res := get("/in", "/in/a.jpg")
	require.Empty(t, res.Error)
	assert.True(t, res.Analysed)
	assert.Empty(t, res.AnalysisError)
	assert.Equal(t, []galleryai.PhotoTag{{Tag: "dog", Score: 0.5}}, res.Tags)
	assert.Equal(t, []galleryai.PhotoFace{{ID: face, Box: galleryai.Box{X1: 0.1, Y1: 0.2, X2: 0.3, Y2: 0.4}, PersonID: alice, PersonName: "Alice"}}, res.Faces)

	res = get("/in", "/in/new.jpg")
	assert.Empty(t, res.Error)
	assert.False(t, res.Analysed)
	assert.Empty(t, res.Faces)
	res = get("/in", "/in/bad.jpg")
	assert.False(t, res.Analysed)
	assert.Equal(t, "unsupported", res.AnalysisError)

	assert.Equal(t, "not found", get("/other", "/in/a.jpg").Error)
	assert.Equal(t, "not found", get("/in", "/in/missing.jpg").Error)
}

func (e *env) assign(t *testing.T, prefix string, req galleryai.FaceAssignRequest) galleryai.FaceResponse {
	req.Prefixes = pfx("p", prefix)
	return call[galleryai.FaceResponse](t, e, galleryai.FaceAssignTopic, req)
}

func (e *env) face(t *testing.T, id string) (person string, manual, deferred bool) {
	require.NoError(t, e.pool.QueryRow(context.Background(), `SELECT coalesce(person_id::text, ''), manual, deferred FROM faces WHERE id = $1`, id).Scan(&person, &manual, &deferred))
	return
}

func (e *env) cover(t *testing.T, person string) (cover string) {
	require.NoError(t, e.pool.QueryRow(context.Background(), `SELECT coalesce(cover_face_id::text, '') FROM persons WHERE id = $1`, person).Scan(&cover))
	return
}

func TestAssignFaceMovesToOtherPersonAndDeletesEmptyOld(t *testing.T) {
	e := start(t)
	alice, bob := e.newPerson(t, "Alice"), e.newPerson(t, "Bob")
	moved := e.seedPersonFace(t, "/in/1.jpg", alice, 0.9)
	e.setCover(t, alice, moved)
	e.seedPersonFace(t, "/in/2.jpg", bob, 0.9)

	res := e.assign(t, "/in", galleryai.FaceAssignRequest{FaceID: moved, PersonID: bob})
	require.Empty(t, res.Error)
	assert.Equal(t, bob, res.Face.PersonID)
	assert.Equal(t, "Bob", res.Face.PersonName)
	assert.True(t, res.Face.Manual)
	person, manual, deferred := e.face(t, moved)
	assert.Equal(t, bob, person)
	assert.True(t, manual)
	assert.False(t, deferred)
	assert.Equal(t, 1, e.count(t, "persons")) // alice was left empty
}

func TestAssignFaceRecoversOldPersonWhenCoverMoves(t *testing.T) {
	e := start(t)
	alice, bob := e.newPerson(t, "Alice"), e.newPerson(t, "Bob")
	cover := e.seedPersonFace(t, "/in/1.jpg", alice, 0.9)
	other := e.seedPersonFace(t, "/in/2.jpg", alice, 0.8)
	e.setCover(t, alice, cover)
	e.seedPersonFace(t, "/in/3.jpg", bob, 0.9)

	require.Empty(t, e.assign(t, "/in", galleryai.FaceAssignRequest{FaceID: cover, PersonID: bob}).Error)
	assert.Equal(t, other, e.cover(t, alice))
}

func TestAssignFaceNewPersonAndUnassign(t *testing.T) {
	e := start(t)
	alice := e.newPerson(t, "Alice")
	face := e.seedPersonFace(t, "/in/1.jpg", alice, 0.9)
	e.setCover(t, alice, face)

	res := e.assign(t, "/in", galleryai.FaceAssignRequest{FaceID: face, NewPersonName: "Zed"})
	require.Empty(t, res.Error)
	assert.Equal(t, "Zed", res.Face.PersonName)
	assert.NotEqual(t, alice, res.Face.PersonID)
	assert.Equal(t, face, e.cover(t, res.Face.PersonID))
	assert.Equal(t, 1, e.count(t, "persons"))

	res = e.assign(t, "/in", galleryai.FaceAssignRequest{FaceID: face, Unassign: true})
	require.Empty(t, res.Error)
	assert.Empty(t, res.Face.PersonID)
	assert.True(t, res.Face.Manual)
	assert.Equal(t, 0, e.count(t, "persons"))

	// three similar faces would form a person, but the manual one stays unassigned
	e.seedPersonFace(t, "/in/2.jpg", "", 0.9)
	e.seedPersonFace(t, "/in/3.jpg", "", 0.9)
	_, err := e.pool.Exec(context.Background(), `UPDATE faces SET clustered = false WHERE NOT manual`)
	require.NoError(t, err)
	require.True(t, galleryai.ClusterTick(e.svc, context.Background()))
	person, manual, _ := e.face(t, face)
	assert.Empty(t, person)
	assert.True(t, manual)
}

func TestAssignFaceRejectsInvalidAndInvisible(t *testing.T) {
	e := start(t)
	alice, hidden := e.newPerson(t, "Alice"), e.newPerson(t, "Hidden")
	face := e.seedPersonFace(t, "/in/1.jpg", alice, 0.9)
	e.seedPersonFace(t, "/out/h.jpg", hidden, 0.9)
	outFace := e.seedPersonFace(t, "/out/2.jpg", alice, 0.9)

	assert.NotEmpty(t, e.assign(t, "/in", galleryai.FaceAssignRequest{FaceID: face}).Error)
	assert.NotEmpty(t, e.assign(t, "/in", galleryai.FaceAssignRequest{FaceID: face, PersonID: alice, NewPersonName: "X"}).Error)
	assert.NotEmpty(t, e.assign(t, "/in", galleryai.FaceAssignRequest{FaceID: face, Unassign: true, PersonID: alice}).Error)
	// face in an invisible photo
	assert.Equal(t, "not found", e.assign(t, "/in", galleryai.FaceAssignRequest{FaceID: outFace, Unassign: true}).Error)
	// target person only in invisible photos
	assert.Equal(t, "not found", e.assign(t, "/in", galleryai.FaceAssignRequest{FaceID: face, PersonID: hidden}).Error)
	person, manual, _ := e.face(t, face)
	assert.Equal(t, alice, person)
	assert.False(t, manual)
}
