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
	"encoding/json"
	"fmt"
	"math"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/gallery-ai/galleryai"
)

// ang is a unit face embedding at deg degrees in the first two dimensions, so the cosine
// distance between two of them is 1 - cos(difference).
func ang(deg float64) string {
	r := deg * math.Pi / 180
	return vec2(float32(math.Cos(r)), float32(math.Sin(r)))
}

// addPhoto publishes an upsert for path whose analysis returns one face per embedding.
func (e *env) addPhoto(t *testing.T, path string, embs ...string) {
	e.ml.faces.Store(path, embs)
	e.publishPath(t, path, events.GalleryPhotoUpserted, 1)
	e.waitAcked(t)
}

func (e *env) publishPath(t *testing.T, path, change string, seq int64) {
	data, _ := json.Marshal(events.GalleryPhotoChangedEvent{ProviderID: "p", Path: path, Change: change, Seq: seq})
	_, err := e.js.Publish(context.Background(), events.GalleryPhotoChangedTopic, data)
	require.NoError(t, err)
	e.waitAcked(t)
}

func (e *env) pass(t *testing.T) {
	require.NoError(t, galleryai.ClusterPass(e.svc, context.Background()))
}

// seedFace inserts an already clustered face (and its photo) directly.
func (e *env) seedFace(t *testing.T, path, emb string, person *string, manual bool) string {
	ctx := context.Background()
	_, err := e.pool.Exec(ctx, `INSERT INTO photos (provider_id, path, seq, model) VALUES ('p', $1, 1, 'clip-test') ON CONFLICT DO NOTHING`, path)
	require.NoError(t, err)
	var id string
	require.NoError(t, e.pool.QueryRow(ctx, `
		INSERT INTO faces (provider_id, path, box_x1, box_y1, box_x2, box_y2, score, person_id, manual, clustered, embedding)
		VALUES ('p', $1, 0, 0, 1, 1, 0.9, $2, $3, true, $4::text::vector) RETURNING id::text`, path, person, manual, emb).Scan(&id))
	return id
}

func (e *env) seedPerson(t *testing.T, cover string) string {
	var id string
	require.NoError(t, e.pool.QueryRow(context.Background(), `INSERT INTO persons (cover_face_id) VALUES ($1) RETURNING id::text`, cover).Scan(&id))
	return id
}

// personOf returns face person ids by photo path ("" for unassigned).
func (e *env) personOf(t *testing.T) map[string]string {
	rows, err := e.pool.Query(context.Background(), `SELECT path, coalesce(person_id::text, '') FROM faces`)
	require.NoError(t, err)
	defer rows.Close()
	m := map[string]string{}
	for rows.Next() {
		var path, person string
		require.NoError(t, rows.Scan(&path, &person))
		m[path] = person
	}
	return m
}

func (e *env) deferred(t *testing.T, path string) (deferred bool) {
	require.NoError(t, e.pool.QueryRow(context.Background(), `SELECT deferred FROM faces WHERE path = $1`, path).Scan(&deferred))
	return
}

func TestThreeSimilarFacesFormOnePersonAndFourthJoins(t *testing.T) {
	e := start(t)
	e.addPhoto(t, "/1.jpg", ang(0))
	e.addPhoto(t, "/2.jpg", ang(1))
	e.addPhoto(t, "/3.jpg", ang(2))
	// the third face is the first core one and creates the person; the earlier two were deferred
	assert.Equal(t, 1, e.count(t, "persons"))
	assert.True(t, e.deferred(t, "/1.jpg"))
	e.pass(t)

	m := e.personOf(t)
	require.NotEmpty(t, m["/1.jpg"])
	assert.Equal(t, m["/1.jpg"], m["/2.jpg"])
	assert.Equal(t, m["/1.jpg"], m["/3.jpg"])
	assert.False(t, e.deferred(t, "/1.jpg"))

	e.addPhoto(t, "/4.jpg", ang(3))
	m = e.personOf(t)
	assert.Equal(t, m["/1.jpg"], m["/4.jpg"])
	assert.Equal(t, 1, e.count(t, "persons"))
}

func TestIsolatedFaceStaysUnassigned(t *testing.T) {
	e := start(t)
	e.addPhoto(t, "/1.jpg", ang(0))
	e.pass(t)
	assert.Equal(t, map[string]string{"/1.jpg": ""}, e.personOf(t))
	assert.False(t, e.deferred(t, "/1.jpg"))
	assert.Equal(t, 0, e.count(t, "persons"))
}

func TestNonCoreFaceNearPersonJoinsOnDeferredPass(t *testing.T) {
	e := start(t)
	cover := e.seedFace(t, "/seed.jpg", ang(0), nil, false)
	person := e.seedPerson(t, cover)
	_, err := e.pool.Exec(context.Background(), `UPDATE faces SET person_id = $1`, person)
	require.NoError(t, err)

	e.addPhoto(t, "/new.jpg", ang(40)) // only 2 faces within 0.5: not core
	assert.Equal(t, "", e.personOf(t)["/new.jpg"])
	assert.True(t, e.deferred(t, "/new.jpg"))

	e.pass(t)
	assert.Equal(t, person, e.personOf(t)["/new.jpg"])
	assert.False(t, e.deferred(t, "/new.jpg"))
	assert.Equal(t, 1, e.count(t, "persons"))
}

func TestSeparatedClustersFormTwoPersons(t *testing.T) {
	e := start(t)
	for i, deg := range []float64{0, 1, 2, 90, 91, 92} {
		e.addPhoto(t, fmt.Sprintf("/%d.jpg", i), ang(deg))
	}
	e.pass(t)

	m := e.personOf(t)
	assert.Equal(t, 2, e.count(t, "persons"))
	assert.Equal(t, m["/0.jpg"], m["/2.jpg"])
	assert.Equal(t, m["/3.jpg"], m["/5.jpg"])
	assert.NotEmpty(t, m["/0.jpg"])
	assert.NotEqual(t, m["/0.jpg"], m["/3.jpg"])
}

func TestManualFacesAreNeverReassignedButLendTheirPerson(t *testing.T) {
	e := start(t)
	m1 := e.seedFace(t, "/m1.jpg", ang(0), nil, true)
	m2 := e.seedFace(t, "/m2.jpg", ang(1), nil, true)
	person := e.seedPerson(t, m1)
	_, err := e.pool.Exec(context.Background(), `UPDATE faces SET person_id = $1 WHERE id = $2`, person, m1)
	require.NoError(t, err)
	_, err = e.pool.Exec(context.Background(), `UPDATE faces SET person_id = $1 WHERE id = $2`, person, m2)
	require.NoError(t, err)
	e.seedFace(t, "/unassigned.jpg", ang(2), nil, true) // manually unassigned, next to the others

	e.addPhoto(t, "/new.jpg", ang(3)) // core thanks to the manual faces, joins their person at once
	e.pass(t)

	m := e.personOf(t)
	assert.Equal(t, person, m["/new.jpg"])
	assert.Equal(t, person, m["/m1.jpg"])
	assert.Equal(t, person, m["/m2.jpg"])
	assert.Equal(t, "", m["/unassigned.jpg"])
	assert.Equal(t, 1, e.count(t, "persons"))
}

func TestNeverClusteredFacesAreClusteredAtStartup(t *testing.T) {
	e := startSeeded(t, `
		INSERT INTO photos (provider_id, path, seq, model) VALUES ('p','/1.jpg',1,'clip-test'),('p','/2.jpg',1,'clip-test'),('p','/3.jpg',1,'clip-test');
		INSERT INTO faces (provider_id, path, box_x1, box_y1, box_x2, box_y2, score, embedding)
		SELECT 'p', '/' || i || '.jpg', 0, 0, 1, 1, 0.9, '`+ang(float64(0))+`'::text::vector FROM generate_series(1,3) i`)
	require.Eventually(t, func() bool {
		m := e.personOf(t)
		return m["/1.jpg"] != "" && m["/1.jpg"] == m["/2.jpg"] && m["/2.jpg"] == m["/3.jpg"]
	}, 10*time.Second, 50*time.Millisecond)
}

func clusterOfThree(t *testing.T) *env {
	e := start(t)
	for i, deg := range []float64{0, 1, 2} {
		e.addPhoto(t, fmt.Sprintf("/%d.jpg", i), ang(deg))
	}
	e.pass(t)
	require.Equal(t, 1, e.count(t, "persons"))
	return e
}

func TestPersonDeletedWhenAllItsPhotosAreDeleted(t *testing.T) {
	e := clusterOfThree(t)
	for i := range 3 {
		e.publishPath(t, fmt.Sprintf("/%d.jpg", i), events.GalleryPhotoDeleted, 2)
	}
	assert.Equal(t, 0, e.count(t, "persons"))
	assert.Equal(t, 0, e.count(t, "faces"))
}

func TestCoverMovesWhenCoverPhotoIsDeleted(t *testing.T) {
	e := clusterOfThree(t)
	var cover, coverPath string
	require.NoError(t, e.pool.QueryRow(context.Background(),
		`SELECT p.cover_face_id::text, f.path FROM persons p JOIN faces f ON f.id = p.cover_face_id`).Scan(&cover, &coverPath))

	e.publishPath(t, coverPath, events.GalleryPhotoDeleted, 2)

	var newCover string
	require.NoError(t, e.pool.QueryRow(context.Background(),
		`SELECT p.cover_face_id::text FROM persons p JOIN faces f ON f.id = p.cover_face_id AND f.person_id = p.id`).Scan(&newCover))
	assert.NotEqual(t, cover, newCover)
	assert.Equal(t, 1, e.count(t, "persons"))
}

func TestLoneFaceJoinsPersonThatAppearsLaterAndIdleTickDoesNothing(t *testing.T) {
	e := start(t)
	ctx := context.Background()
	drain := func() {
		for i := 0; galleryai.ClusterTick(e.svc, ctx); i++ {
			require.Less(t, i, 5)
		}
	}
	e.addPhoto(t, "/1.jpg", ang(0))
	drain()
	assert.Equal(t, "", e.personOf(t)["/1.jpg"]) // alone: nothing to join yet

	e.addPhoto(t, "/2.jpg", ang(1))
	e.addPhoto(t, "/3.jpg", ang(2)) // core: creates the person
	e.addPhoto(t, "/4.jpg", ang(3))
	require.True(t, galleryai.ClusterTick(e.svc, ctx))
	m := e.personOf(t)
	require.NotEmpty(t, m["/3.jpg"])
	for _, p := range []string{"/1.jpg", "/2.jpg", "/4.jpg"} {
		assert.Equal(t, m["/3.jpg"], m[p], p)
	}

	require.Eventually(t, func() bool { return e.jobs.last("gallery-ai.clustering").State == "completed" }, 10*time.Second, 50*time.Millisecond)
	clustering := e.jobs.last("gallery-ai.clustering")
	assert.Equal(t, clustering.Total, clustering.Done)

	drain()
	time.Sleep(200 * time.Millisecond) // let in-flight job events arrive
	published := len(e.jobs.history("gallery-ai.clustering"))
	assert.False(t, galleryai.ClusterTick(e.svc, ctx)) // nothing assigned since the last pass
	time.Sleep(200 * time.Millisecond)
	assert.Len(t, e.jobs.history("gallery-ai.clustering"), published, "a gated pass must publish nothing")
	assert.Equal(t, 1, e.count(t, "persons"))
}
