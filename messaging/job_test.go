// Copyright © 2026 Benjamin Schmitz
// This file is part of Seraph <https://github.com/Vortex375/seraph>.
// Licensed under the GNU Affero General Public License v3 or later.

package messaging

import (
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"umbasa.net/seraph/events"
)

type jobRig struct {
	nc   *nats.Conn
	job  *Job
	mu   sync.Mutex
	recv []events.JobEvent
}

func (r *jobRig) events() []events.JobEvent {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]events.JobEvent(nil), r.recv...)
}

func newJobRig(t *testing.T, throttle, heartbeat time.Duration) *jobRig {
	t.Helper()
	srv, err := server.NewServer(&server.Options{Port: -1})
	require.NoError(t, err)
	go srv.Start()
	require.True(t, srv.ReadyForConnections(5*time.Second))
	t.Cleanup(srv.Shutdown)

	nc, err := nats.Connect(srv.ClientURL())
	require.NoError(t, err)
	t.Cleanup(nc.Close)

	r := &jobRig{nc: nc}
	_, err = nc.Subscribe("seraph.jobs.test.job", func(m *nats.Msg) {
		ev := events.JobEvent{}
		if assert.NoError(t, ev.Unmarshal(m.Data)) {
			r.mu.Lock()
			r.recv = append(r.recv, ev)
			r.mu.Unlock()
		}
	})
	require.NoError(t, err)

	r.job = NewJob(nc, "test.job", "Test job")
	r.job.throttle, r.job.heartbeat = throttle, heartbeat
	t.Cleanup(r.job.Close)
	return r
}

func TestJobThrottleTrailingFlush(t *testing.T) {
	r := newJobRig(t, 300*time.Millisecond, time.Minute)
	for i := int64(1); i <= 100; i++ {
		r.job.Progress(i, 100, "step")
	}
	require.Eventually(t, func() bool { return len(r.events()) == 1 }, time.Second, 5*time.Millisecond)
	assert.Equal(t, int64(1), r.events()[0].Done)
	assert.Equal(t, "running", r.events()[0].State)

	assert.Eventually(t, func() bool { return len(r.events()) == 2 }, 2*time.Second, 20*time.Millisecond)
	time.Sleep(500 * time.Millisecond)
	evs := r.events()
	require.Len(t, evs, 2)
	assert.Equal(t, int64(100), evs[1].Done)
	assert.Equal(t, int64(100), evs[1].Total)
}

func TestJobStateChangeIsImmediate(t *testing.T) {
	r := newJobRig(t, time.Hour, time.Hour)
	r.job.Progress(1, 10, "a")
	r.job.Progress(2, 10, "b") // throttled
	r.job.Complete("done")
	r.job.Pending(5, "queue") // completed -> running
	r.job.Pending(0, "empty") // running -> idle
	r.job.Fail(errors.New("boom"))
	require.NoError(t, r.nc.Flush())

	assert.Eventually(t, func() bool { return len(r.events()) == 5 }, time.Second, 10*time.Millisecond)
	var states []string
	for _, e := range r.events() {
		states = append(states, e.State)
	}
	assert.Equal(t, []string{"running", "completed", "running", "idle", "failed"}, states)
	evs := r.events()
	assert.Equal(t, int64(2), evs[1].Done)
	assert.Equal(t, int64(0), evs[3].Pending)
	assert.Equal(t, "boom", evs[4].StatusMessage)
}

func TestJobHeartbeat(t *testing.T) {
	r := newJobRig(t, time.Hour, 100*time.Millisecond)
	r.job.Progress(1, -1, "x")
	assert.Eventually(t, func() bool { return len(r.events()) >= 3 }, 2*time.Second, 20*time.Millisecond)

	r.job.Complete("ok")
	time.Sleep(100 * time.Millisecond)
	n := len(r.events())
	time.Sleep(500 * time.Millisecond)
	assert.Equal(t, n, len(r.events()), "completed job must not heartbeat")
	assert.Equal(t, "completed", r.events()[n-1].State)
}

func TestJobIdleQueuePublishesOnce(t *testing.T) {
	r := newJobRig(t, 10*time.Millisecond, time.Hour)
	for i := 0; i < 5; i++ {
		r.job.Pending(0, "Up to date")
		time.Sleep(30 * time.Millisecond) // past the throttle window each time
	}
	require.NoError(t, r.nc.Flush())
	time.Sleep(50 * time.Millisecond)
	require.Len(t, r.events(), 1)
	assert.Equal(t, "idle", r.events()[0].State)
}

func TestJobPublishErrorDoesNotPanic(t *testing.T) {
	r := newJobRig(t, time.Millisecond, 10*time.Millisecond)
	r.nc.Close()
	assert.NotPanics(t, func() {
		r.job.Progress(1, 2, "x")
		r.job.Fail(errors.New("x"))
		r.job.Complete("x")
	})
}
