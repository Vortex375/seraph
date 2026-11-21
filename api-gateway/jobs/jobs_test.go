// Copyright © 2026 Benjamin Schmitz
// This file is part of Seraph <https://github.com/Vortex375/seraph>.
// Licensed under the GNU Affero General Public License v3 or later.

package jobs

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"umbasa.net/seraph/events"
	seraphjobs "umbasa.net/seraph/jobs/jobs"
	"umbasa.net/seraph/logging"
)

type fakeAuth struct{ admin bool }

func (a fakeAuth) AuthMiddleware(bool, string) func(*gin.Context) bool {
	return func(*gin.Context) bool { return true }
}
func (a fakeAuth) GetUserId(context.Context) string  { return "u" }
func (a fakeAuth) IsSpaceAdmin(context.Context) bool { return a.admin }

func newRig(t *testing.T, admin bool) (*gin.Engine, jetstream.KeyValue) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	srv, err := server.NewServer(&server.Options{Port: -1, JetStream: true, StoreDir: t.TempDir()})
	require.NoError(t, err)
	go srv.Start()
	require.True(t, srv.ReadyForConnections(10*time.Second))
	t.Cleanup(srv.Shutdown)
	nc, err := nats.Connect(srv.ClientURL())
	require.NoError(t, err)
	t.Cleanup(nc.Close)
	js, err := jetstream.New(nc)
	require.NoError(t, err)

	res, err := New(Params{Log: logging.New(logging.Params{}), Nc: nc, Js: js, Auth: fakeAuth{admin}})
	require.NoError(t, err)
	kv, err := js.KeyValue(context.Background(), seraphjobs.BucketConfig.Bucket)
	require.NoError(t, err)

	app := gin.New()
	res.Handler.Setup(app, app.Group("/api"), app.Group("/public"))
	return app, kv
}

func get(app *gin.Engine) *httptest.ResponseRecorder {
	w := httptest.NewRecorder()
	app.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/api/jobs", nil))
	return w
}

func TestJobsForbiddenForNonAdmin(t *testing.T) {
	app, _ := newRig(t, false)
	assert.Equal(t, http.StatusForbidden, get(app).Code)
}

func TestJobsEmptyBucketIsEmptyArray(t *testing.T) {
	app, _ := newRig(t, true)
	w := get(app)
	assert.Equal(t, http.StatusOK, w.Code)
	assert.JSONEq(t, "[]", w.Body.String())
}

func TestJobsListsEntriesAndSkipsOldSchema(t *testing.T) {
	app, kv := newRig(t, true)
	ctx := context.Background()

	ev := events.JobEvent{Key: "a", Description: "Job A", StatusMessage: "hi", State: "running", Done: 3, Total: 10, Pending: -1}
	b, err := ev.Marshal()
	require.NoError(t, err)
	_, err = kv.Put(ctx, "a", b)
	require.NoError(t, err)

	// pre-schema-change entry: same bytes without the four trailing fields
	old := events.JobEvent{Key: "old", Description: "Old"}
	ob, err := old.Marshal()
	require.NoError(t, err)
	_, err = kv.Put(ctx, "old", ob[:len(ob)-4])
	require.NoError(t, err)

	w := get(app)
	require.Equal(t, http.StatusOK, w.Code)
	var got []map[string]any
	require.NoError(t, json.Unmarshal(w.Body.Bytes(), &got))
	require.Len(t, got, 1)
	for _, k := range []string{"key", "description", "statusMessage", "state", "done", "total", "pending", "time"} {
		assert.Contains(t, got[0], k)
	}
	assert.Equal(t, "a", got[0]["key"])
	assert.EqualValues(t, 3, got[0]["done"])
}
