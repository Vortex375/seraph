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
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/gallery-ai/galleryai"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/tracing"
)

var (
	setupOnce   sync.Once
	setupErr    error
	natsServer  *server.Server
	pgContainer testcontainers.Container
	dbURL       string
)

func TestMain(m *testing.M) {
	code := m.Run()
	if natsServer != nil {
		natsServer.Shutdown()
	}
	if pgContainer != nil {
		testcontainers.TerminateContainer(pgContainer)
	}
	os.Exit(code)
}

// requireIntegration starts embedded NATS and a pgvector Postgres once, and
// skips the calling test when Docker is unavailable.
func requireIntegration(t *testing.T) {
	t.Helper()
	setupOnce.Do(func() { setupErr = setup() })
	if setupErr != nil {
		t.Skipf("integration environment unavailable: %v", setupErr)
	}
}

func setup() error {
	var err error
	natsServer, err = server.NewServer(&server.Options{JetStream: true, StoreDir: os.TempDir() + "/gallery-ai-test-nats", Port: server.RANDOM_PORT})
	if err != nil {
		return fmt.Errorf("embedded NATS: %w", err)
	}
	natsServer.Start()
	if !natsServer.ReadyForConnections(10 * time.Second) {
		return fmt.Errorf("embedded NATS server did not become ready")
	}

	pgContainer, err = testcontainers.GenericContainer(context.Background(), testcontainers.GenericContainerRequest{
		ContainerRequest: testcontainers.ContainerRequest{
			Image:        "agnohq/pgvector:18",
			ExposedPorts: []string{"5432/tcp"},
			Env:          map[string]string{"POSTGRES_USER": "ai", "POSTGRES_PASSWORD": "ai", "POSTGRES_DB": "gallery_ai_test"},
			WaitingFor:   wait.ForLog("database system is ready to accept connections").WithOccurrence(2).WithStartupTimeout(2 * time.Minute),
		},
		Started: true,
	})
	if err != nil {
		return fmt.Errorf("starting postgres testcontainer (is Docker available?): %w", err)
	}
	endpoint, err := pgContainer.Endpoint(context.Background(), "")
	if err != nil {
		return err
	}
	dbURL = fmt.Sprintf("postgres://ai:ai@%s/gallery_ai_test?sslmode=disable", endpoint)
	// the readiness log line can precede the first accepted connection
	for deadline := time.Now().Add(30 * time.Second); ; time.Sleep(500 * time.Millisecond) {
		if err = galleryai.ApplyMigrations(dbURL); err == nil || time.Now().After(deadline) {
			return err
		}
	}
}

// fakeML is an httptest stand-in for the Immich machine-learning container.
type fakeML struct {
	srv     *httptest.Server
	calls   atomic.Int32
	status  atomic.Int32
	entries atomic.Value // last "entries" form field

	textStatus atomic.Int32 // status for text (tag prompt) requests
	visual     atomic.Int32 // image requests seen

	faces sync.Map // photo path -> []string face embeddings (vec JSON); default one face vec(2)
}

func vec(first float32) string {
	v := make([]float32, 512)
	v[0] = first
	b, _ := json.Marshal(v)
	return string(b)
}

// vec2 is a 512-d vector with only the first two components set.
func vec2(a, b float32) string {
	v := make([]float32, 512)
	v[0], v[1] = a, b
	out, _ := json.Marshal(v)
	return string(out)
}

func newFakeML(t *testing.T) *fakeML {
	f := &fakeML{}
	f.status.Store(200)
	f.textStatus.Store(200)
	f.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.calls.Add(1)
		if s := int(f.status.Load()); s != 200 {
			http.Error(w, "boom", s)
			return
		}
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			http.Error(w, err.Error(), 400)
			return
		}
		f.entries.Store(r.FormValue("entries"))
		w.Header().Set("Content-Type", "application/json")
		if text := r.FormValue("text"); text != "" {
			if s := int(f.textStatus.Load()); s != 200 {
				http.Error(w, "boom", s)
				return
			}
			// prompt "match" is parallel to the fake image embedding, anything else orthogonal
			emb := vec2(0, 1)
			if text == "match" {
				emb = vec2(1, 0)
			}
			json.NewEncoder(w).Encode(map[string]any{"clip": emb})
			return
		}
		f.visual.Add(1)
		embs := []string{vec(2)}
		if img, _, err := r.FormFile("image"); err == nil {
			path, _ := io.ReadAll(img)
			if v, ok := f.faces.Load(string(path)); ok {
				embs = v.([]string)
			}
		}
		faces := []map[string]any{}
		for _, emb := range embs {
			faces = append(faces, map[string]any{
				"boundingBox": map[string]int{"x1": 100, "y1": 50, "x2": 200, "y2": 150},
				"embedding":   emb,
				"score":       0.9,
			})
		}
		json.NewEncoder(w).Encode(map[string]any{
			"clip":               vec(1),
			"facial-recognition": faces,
			"imageWidth":         400,
			"imageHeight":        200,
		})
	}))
	t.Cleanup(f.srv.Close)
	return f
}

type fakeThumbs struct {
	err   error
	calls atomic.Int32
}

func (f *fakeThumbs) Thumbnail(ctx context.Context, providerID, path string) ([]byte, error) {
	f.calls.Add(1)
	if f.err != nil {
		return nil, f.err
	}
	return []byte(path), nil
}

type env struct {
	pool   *pgxpool.Pool
	js     jetstream.JetStream
	nc     *nats.Conn
	ml     *fakeML
	thumbs *fakeThumbs
	svc    *galleryai.Service
	stop   func()
}

func start(t *testing.T) *env { return startSeeded(t, "") }

// startSeeded runs seedSQL (if any) before the service starts.
func startSeeded(t *testing.T, seedSQL string) *env {
	return startWith(t, startOpts{seed: seedSQL})
}

type startOpts struct {
	seed string
	keep bool // keep the database content of a previous start (no truncate)
	tags []galleryai.TagConfig
	hook func(*pgxpool.Pool) // runs once before the re-tag pass records its result
	down bool                // ML text requests fail until fakeML.textStatus is reset
}

func startWith(t *testing.T, o startOpts) *env {
	seedSQL := o.seed
	requireIntegration(t)

	pool, err := pgxpool.New(context.Background(), dbURL)
	require.NoError(t, err)
	t.Cleanup(pool.Close)
	if !o.keep {
		_, err = pool.Exec(context.Background(), `TRUNCATE photos, persons, faces, photo_embeddings, photo_tags CASCADE; UPDATE tag_state SET config_hash = ''`)
		require.NoError(t, err)
	}
	if seedSQL != "" {
		_, err = pool.Exec(context.Background(), seedSQL)
		require.NoError(t, err)
	}

	nc, err := nats.Connect(natsServer.ClientURL())
	require.NoError(t, err)
	t.Cleanup(nc.Close)
	js, err := jetstream.New(nc)
	require.NoError(t, err)

	e := &env{pool: pool, js: js, nc: nc, ml: newFakeML(t), thumbs: &fakeThumbs{}}
	if o.down {
		e.ml.textStatus.Store(503)
	}
	cfg := galleryai.Config{MLURL: e.ml.srv.URL, ClipModel: "clip-test", FaceModel: "buffalo_l", FaceMinScore: 0.7, MaxDistance: 0.5, MinFaces: 3, DeferredInterval: time.Hour, MaxAckPending: 2, Tags: o.tags}
	svc := galleryai.New(galleryai.Params{
		Config: cfg, Pool: pool, ML: galleryai.NewMLClient(cfg), Thumbs: e.thumbs, Js: js, Nc: nc,
		Logger: logging.New(logging.Params{}), Tracing: tracing.NewNoopTracing(),
	})
	e.svc = svc
	galleryai.SetRetryDelay(svc, 200*time.Millisecond)
	galleryai.SetTagRetryDelay(svc, 50*time.Millisecond)
	if o.hook != nil {
		var once sync.Once
		galleryai.SetBeforeTagStateWrite(svc, func() { once.Do(func() { o.hook(pool) }) })
	}
	require.NoError(t, svc.Start())
	var stopOnce sync.Once
	e.stop = func() { stopOnce.Do(svc.Stop) }
	t.Cleanup(func() {
		e.stop()
		js.DeleteStream(context.Background(), events.GalleryPhotoChangedStream)
	})
	return e
}

func (e *env) publish(t *testing.T, change string, seq int64) {
	data, _ := json.Marshal(events.GalleryPhotoChangedEvent{ProviderID: "p", Path: "/a.jpg", Change: change, Seq: seq})
	_, err := e.js.Publish(context.Background(), events.GalleryPhotoChangedTopic, data)
	require.NoError(t, err)
}

// waitAcked waits until the work-queue stream is empty, i.e. everything was acked.
func (e *env) waitAcked(t *testing.T) {
	t.Helper()
	require.Eventually(t, func() bool {
		s, err := e.js.Stream(context.Background(), events.GalleryPhotoChangedStream)
		if err != nil {
			return false
		}
		info, err := s.Info(context.Background())
		return err == nil && info.State.Msgs == 0
	}, 10*time.Second, 50*time.Millisecond)
}

func (e *env) count(t *testing.T, table string) int {
	var n int
	require.NoError(t, e.pool.QueryRow(context.Background(), `SELECT count(*) FROM `+table).Scan(&n))
	return n
}

func (e *env) photo(t *testing.T) (seq int64, deleted bool, errText *string) {
	require.NoError(t, e.pool.QueryRow(context.Background(), `SELECT seq, deleted, error FROM photos WHERE provider_id='p' AND path='/a.jpg'`).Scan(&seq, &deleted, &errText))
	return
}

func TestUpsertedStoresEmbeddingAndNormalisedFaces(t *testing.T) {
	e := start(t)
	e.publish(t, events.GalleryPhotoUpserted, 5)
	e.waitAcked(t)

	seq, deleted, errText := e.photo(t)
	assert.EqualValues(t, 5, seq)
	assert.False(t, deleted)
	assert.Nil(t, errText)
	assert.Equal(t, 1, e.count(t, "photo_embeddings"))
	assert.Equal(t, 1, e.count(t, "faces"))

	var x1, y1, x2, y2, score float32
	require.NoError(t, e.pool.QueryRow(context.Background(), `SELECT box_x1, box_y1, box_x2, box_y2, score FROM faces`).Scan(&x1, &y1, &x2, &y2, &score))
	assert.Equal(t, []float32{0.25, 0.25, 0.5, 0.75}, []float32{x1, y1, x2, y2})
	assert.InDelta(t, 0.9, score, 1e-6)

	var model string
	require.NoError(t, e.pool.QueryRow(context.Background(), `SELECT model FROM photos`).Scan(&model))
	assert.Equal(t, "clip-test", model)
	assert.Contains(t, e.ml.entries.Load(), `"modelName":"clip-test"`)
}

func TestStaleAndReplayedUpsertedAckedWithoutML(t *testing.T) {
	e := start(t)
	e.publish(t, events.GalleryPhotoUpserted, 5)
	e.waitAcked(t)
	require.EqualValues(t, 1, e.ml.calls.Load())

	e.publish(t, events.GalleryPhotoUpserted, 5) // replay
	e.publish(t, events.GalleryPhotoUpserted, 3) // stale
	e.waitAcked(t)

	assert.EqualValues(t, 1, e.ml.calls.Load())
	assert.EqualValues(t, 1, e.thumbs.calls.Load())
	seq, _, _ := e.photo(t)
	assert.EqualValues(t, 5, seq)
}

func TestDeletedRemovesResultsAndStaleUpsertDoesNotResurrect(t *testing.T) {
	e := start(t)
	e.publish(t, events.GalleryPhotoUpserted, 5)
	e.waitAcked(t)

	_, err := e.pool.Exec(context.Background(), `INSERT INTO photo_tags VALUES ('p', '/a.jpg', 'pet', 0.9)`)
	require.NoError(t, err)
	_, err = e.pool.Exec(context.Background(), `
		WITH p AS (INSERT INTO persons DEFAULT VALUES RETURNING id)
		UPDATE faces SET person_id = (SELECT id FROM p)`)
	require.NoError(t, err)

	e.publish(t, events.GalleryPhotoDeleted, 6)
	e.waitAcked(t)

	seq, deleted, _ := e.photo(t)
	assert.EqualValues(t, 6, seq)
	assert.True(t, deleted)
	for _, table := range []string{"photo_embeddings", "photo_tags", "faces", "persons"} {
		assert.Equal(t, 0, e.count(t, table), table)
	}

	calls := e.ml.calls.Load()
	e.publish(t, events.GalleryPhotoUpserted, 4)
	e.waitAcked(t)
	assert.Equal(t, calls, e.ml.calls.Load())
	assert.Equal(t, 0, e.count(t, "photo_embeddings"))
	_, deleted, _ = e.photo(t)
	assert.True(t, deleted)
}

func TestUnsupportedThumbnailRecordsErrorAndAcks(t *testing.T) {
	e := start(t)
	e.thumbs.err = galleryai.PermanentForTest(fmt.Errorf("thumbnailer: unsupported"))
	e.publish(t, events.GalleryPhotoUpserted, 2)
	e.waitAcked(t)

	seq, _, errText := e.photo(t)
	assert.EqualValues(t, 2, seq)
	require.NotNil(t, errText)
	assert.True(t, strings.Contains(*errText, "unsupported"))
	assert.EqualValues(t, 0, e.ml.calls.Load())
	assert.Equal(t, 0, e.count(t, "photo_embeddings"))
}

func TestML503LeavesMessageUnackedUntilRecovery(t *testing.T) {
	e := start(t)
	e.ml.status.Store(503)
	e.publish(t, events.GalleryPhotoUpserted, 1)

	require.Eventually(t, func() bool { return e.ml.calls.Load() >= 2 }, 10*time.Second, 50*time.Millisecond, "message must be redelivered")
	assert.Equal(t, 0, e.count(t, "photos"))
	s, err := e.js.Stream(context.Background(), events.GalleryPhotoChangedStream)
	require.NoError(t, err)
	info, err := s.Info(context.Background())
	require.NoError(t, err)
	assert.EqualValues(t, 1, info.State.Msgs)

	e.ml.status.Store(200)
	e.waitAcked(t)
	assert.Equal(t, 1, e.count(t, "photo_embeddings"))
}

func TestModelSweepReanalysesOnlyStaleLivePhotos(t *testing.T) {
	e := startSeeded(t, `INSERT INTO photos (provider_id, path, seq, deleted, model) VALUES
		('p', '/old1.jpg', 7, false, 'old'),
		('p', '/old2.jpg', 8, false, NULL),
		('p', '/current.jpg', 9, false, 'clip-test'),
		('p', '/gone.jpg', 10, true, NULL)`)

	require.Eventually(t, func() bool { return e.count(t, "photo_embeddings") == 2 }, 10*time.Second, 50*time.Millisecond)
	assert.EqualValues(t, 2, e.ml.calls.Load())
	assert.EqualValues(t, 2, e.thumbs.calls.Load())

	rows, err := e.pool.Query(context.Background(), `SELECT path, seq, deleted, model FROM photos ORDER BY path`)
	require.NoError(t, err)
	type row struct {
		path    string
		seq     int64
		deleted bool
		model   *string
	}
	var got []row
	for rows.Next() {
		var r row
		require.NoError(t, rows.Scan(&r.path, &r.seq, &r.deleted, &r.model))
		got = append(got, r)
	}
	rows.Close()
	m := "clip-test"
	assert.Equal(t, []row{
		{"/current.jpg", 9, false, &m},
		{"/gone.jpg", 10, true, nil},
		{"/old1.jpg", 7, false, &m},
		{"/old2.jpg", 8, false, &m},
	}, got)
	assert.Equal(t, 0, e.count(t, "photo_embeddings WHERE path IN ('/current.jpg', '/gone.jpg')"))
}

// tag fixtures: the fake image embedding is (1,0); prompt "match" embeds to (1,0), anything else to (0,1)
func tagSet(mixedThreshold float64) []galleryai.TagConfig {
	return []galleryai.TagConfig{
		{Tag: "hit", Prompts: []string{"match"}, Threshold: 0.9},
		{Tag: "miss", Prompts: []string{"other"}, Threshold: 0.1},
		{Tag: "mixed", Prompts: []string{"match", "other"}, Threshold: mixedThreshold}, // cosine 0.7071
	}
}

func (e *env) tags(t *testing.T) map[string]float64 {
	rows, err := e.pool.Query(context.Background(), `SELECT tag, score FROM photo_tags ORDER BY tag`)
	require.NoError(t, err)
	defer rows.Close()
	got := map[string]float64{}
	for rows.Next() {
		var tag string
		var score float64
		require.NoError(t, rows.Scan(&tag, &score))
		got[tag] = score
	}
	return got
}

func TestAnalysisStoresTagsAboveThresholdOnly(t *testing.T) {
	e := startWith(t, startOpts{tags: tagSet(0.7)})
	e.publish(t, events.GalleryPhotoUpserted, 1)
	e.waitAcked(t)
	require.Eventually(t, func() bool { return e.count(t, "photo_tags") > 0 }, 10*time.Second, 50*time.Millisecond)

	got := e.tags(t)
	assert.Len(t, got, 2)
	assert.InDelta(t, 1.0, got["hit"], 1e-5)
	assert.InDelta(t, 0.7071, got["mixed"], 1e-3)
}

// seeds one live photo per path with embedding (1,0), the current model and stale tags
const seedTagged = `
	INSERT INTO photos (provider_id, path, seq, model) VALUES ('p', '/1.jpg', 1, 'clip-test'), ('p', '/2.jpg', 2, 'clip-test');
	INSERT INTO photo_embeddings SELECT provider_id, path, ('[1,' || repeat('0,', 510) || '0]')::vector FROM photos;
	INSERT INTO photo_tags SELECT provider_id, path, 'stale', 1 FROM photos;`

func TestTagConfigChangeRetagsFromStoredEmbeddingsWithoutImageCalls(t *testing.T) {
	cfgHash := func(e *env) string {
		var h string
		require.NoError(t, e.pool.QueryRow(context.Background(), `SELECT config_hash FROM tag_state`).Scan(&h))
		return h
	}

	e1 := startWith(t, startOpts{seed: seedTagged, tags: tagSet(0.7)})
	require.Eventually(t, func() bool { return cfgHash(e1) != "" }, 10*time.Second, 50*time.Millisecond)
	assert.Equal(t, 4, e1.count(t, "photo_tags")) // hit + mixed on both photos, stale gone
	e1.stop()

	e2 := startWith(t, startOpts{keep: true, tags: tagSet(0.8)})
	require.Eventually(t, func() bool { return e2.count(t, "photo_tags") == 2 }, 10*time.Second, 50*time.Millisecond)
	assert.Equal(t, map[string]float64{"hit": 1}, roundTags(e2.tags(t)))
	assert.EqualValues(t, 0, e2.ml.visual.Load(), "re-tagging must not call the ML server for images")
	assert.EqualValues(t, 0, e2.thumbs.calls.Load())
	e2.stop()

	// unchanged config: no pass, so a hand-planted tag survives
	e3 := startWith(t, startOpts{keep: true, tags: tagSet(0.8)})
	_, err := e3.pool.Exec(context.Background(), `INSERT INTO photo_tags VALUES ('p', '/1.jpg', 'planted', 1)`)
	require.NoError(t, err)
	e3.stop()
	e4 := startWith(t, startOpts{keep: true, tags: tagSet(0.8)})
	time.Sleep(500 * time.Millisecond)
	assert.Equal(t, 3, e4.count(t, "photo_tags"))
}

func roundTags(m map[string]float64) map[string]float64 {
	for k, v := range m {
		m[k] = float64(int(v*100+0.5)) / 100
	}
	return m
}

func TestPhotosStoredBeforeTagEmbeddingsReadyGetTagged(t *testing.T) {
	// first run completes a pass, so only store's "tagging skipped" mark can trigger the next one
	e1 := startWith(t, startOpts{tags: tagSet(0.7)})
	require.Eventually(t, func() bool {
		var h string
		e1.pool.QueryRow(context.Background(), `SELECT config_hash FROM tag_state`).Scan(&h)
		return h != ""
	}, 10*time.Second, 50*time.Millisecond)
	e1.stop()

	e2 := startWith(t, startOpts{keep: true, tags: tagSet(0.7), down: true})
	e2.publish(t, events.GalleryPhotoUpserted, 1)
	e2.waitAcked(t)
	assert.Equal(t, 1, e2.count(t, "photo_embeddings"))
	assert.Equal(t, 0, e2.count(t, "photo_tags"))

	e2.ml.textStatus.Store(200) // ML text endpoint recovers; the background retry picks it up
	require.Eventually(t, func() bool { return e2.count(t, "photo_tags") == 2 }, 10*time.Second, 50*time.Millisecond)
}

// A store that skipped tagging commits after the re-tag pass processed its batches
// but before the pass records its result: the pass must notice and run again.
func TestRetagRerunsWhenTaggingWasSkippedDuringPass(t *testing.T) {
	e := startWith(t, startOpts{seed: seedTagged, tags: tagSet(0.7), hook: func(pool *pgxpool.Pool) {
		_, err := pool.Exec(context.Background(), `
			INSERT INTO photos (provider_id, path, seq, model) VALUES ('p', '/late.jpg', 3, 'clip-test');
			INSERT INTO photo_embeddings VALUES ('p', '/late.jpg', ('[1,' || repeat('0,', 510) || '0]')::vector);
			UPDATE tag_state SET config_hash = 'pending:' || gen_random_uuid()`)
		assert.NoError(t, err)
	}})
	require.Eventually(t, func() bool {
		return e.count(t, "photo_tags WHERE path = '/late.jpg'") == 2
	}, 10*time.Second, 50*time.Millisecond)
	assert.Equal(t, 6, e.count(t, "photo_tags"))
	require.Eventually(t, func() bool {
		var h string
		e.pool.QueryRow(context.Background(), `SELECT config_hash FROM tag_state`).Scan(&h)
		return h != "" && !strings.HasPrefix(h, "pending:")
	}, 10*time.Second, 50*time.Millisecond)
}

func TestEnsureDatabaseCreatesMissingDatabaseIdempotently(t *testing.T) {
	requireIntegration(t)
	url := strings.Replace(dbURL, "/gallery_ai_test?", "/gallery_ai_created?", 1)
	require.NoError(t, galleryai.EnsureDatabase(context.Background(), url))
	require.NoError(t, galleryai.EnsureDatabase(context.Background(), url))
	require.NoError(t, galleryai.ApplyMigrations(url))
}
