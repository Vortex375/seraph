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

package messaging

import (
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"umbasa.net/seraph/events"
)

const (
	jobThrottle  = 5 * time.Second
	jobHeartbeat = 30 * time.Second
)

// Job reports the progress of one background process on seraph.jobs.<key>.
// Updates are throttled, state changes are published at once, and a running
// Job is republished periodically so consumers can detect stalls.
// Publish errors are logged and never returned. Safe for concurrent use.
type Job struct {
	nc          *nats.Conn
	key         string
	description string
	log         *slog.Logger

	throttle  time.Duration
	heartbeat time.Duration

	mu      sync.Mutex
	state   string
	done    int64
	total   int64
	pending int64
	msg     string
	dirty   bool // a value is waiting for the throttle window to end
	sent    jobValues
	last    time.Time
	flush   *time.Timer
	beat    *time.Timer
	closed  bool
}

// NewJob creates a Job reporter. Call Close when the Job's owner shuts down.
func NewJob(nc *nats.Conn, key, description string) *Job {
	return &Job{
		nc:          nc,
		key:         key,
		description: description,
		log:         slog.Default().With("job", key),
		throttle:    jobThrottle,
		heartbeat:   jobHeartbeat,
		total:       -1,
		pending:     -1,
	}
}

// Progress reports a Batch Job as running. total -1 means unknown.
func (j *Job) Progress(done, total int64, msg string) {
	j.update("running", done, total, -1, msg)
}

// Pending reports a Queue Job's backlog: running while n > 0, idle at 0.
func (j *Job) Pending(n int64, msg string) {
	state := "running"
	if n <= 0 {
		state = "idle"
	}
	j.update(state, 0, -1, n, msg)
}

// Complete reports a Batch Job as completed.
func (j *Job) Complete(msg string) {
	j.mu.Lock()
	done, total := j.done, j.total
	j.mu.Unlock()
	j.update("completed", done, total, -1, msg)
}

// Fail reports a Batch Job as failed; the error becomes the status message.
func (j *Job) Fail(err error) {
	j.mu.Lock()
	done, total := j.done, j.total
	j.mu.Unlock()
	j.update("failed", done, total, -1, err.Error())
}

// Close stops the background timers. Later calls are ignored.
func (j *Job) Close() {
	j.mu.Lock()
	defer j.mu.Unlock()
	j.closed = true
	j.stopTimers()
}

type jobValues struct {
	state                string
	done, total, pending int64
	msg                  string
}

func (j *Job) values() jobValues {
	return jobValues{j.state, j.done, j.total, j.pending, j.msg}
}

func (j *Job) update(state string, done, total, pending int64, msg string) {
	j.mu.Lock()
	defer j.mu.Unlock()
	if j.closed {
		return
	}
	changed := state != j.state
	j.state, j.done, j.total, j.pending, j.msg = state, done, total, pending, msg
	if !j.last.IsZero() && j.values() == j.sent {
		// nothing new: a polled idle Queue Job stays quiet, and a running
		// one is kept fresh by the heartbeat
		j.dirty = false
		return
	}

	since := time.Since(j.last)
	switch {
	case changed || since >= j.throttle:
		j.publish()
	case !j.dirty:
		j.dirty = true
		j.flush = time.AfterFunc(j.throttle-since, j.onFlush)
	default:
		j.dirty = true
	}
}

func (j *Job) onFlush() {
	j.mu.Lock()
	defer j.mu.Unlock()
	if !j.closed && j.dirty {
		j.publish()
	}
}

func (j *Job) onBeat() {
	j.mu.Lock()
	defer j.mu.Unlock()
	if !j.closed && j.state == "running" {
		j.publish()
	}
}

func (j *Job) stopTimers() {
	if j.flush != nil {
		j.flush.Stop()
	}
	if j.beat != nil {
		j.beat.Stop()
	}
}

// publish sends the current values. Caller holds j.mu.
func (j *Job) publish() {
	j.dirty = false
	j.last = time.Now()
	j.sent = j.values()
	j.stopTimers()
	if j.state == "running" {
		j.beat = time.AfterFunc(j.heartbeat, j.onBeat)
	}

	ev := events.JobEvent{
		Event:         events.Event{ID: uuid.NewString(), Version: 1},
		Key:           j.key,
		Description:   j.description,
		StatusMessage: j.msg,
		Properties:    map[string]string{},
		State:         j.state,
		Done:          j.done,
		Total:         j.total,
		Pending:       j.pending,
	}
	data, err := ev.Marshal()
	if err != nil {
		j.log.Error("failed to marshal job event", "error", err)
		return
	}
	if err := j.nc.Publish(fmt.Sprintf(events.JobsTopicPattern, j.key), data); err != nil {
		j.log.Error("failed to publish job event", "error", err)
	}
}
