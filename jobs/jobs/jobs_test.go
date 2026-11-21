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

package jobs

import (
	"context"
	"testing"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
)

// a stored Job event must be acked: unacked ones are redelivered and rewritten
// every AckWait, which keeps every Job's update time fresh
func TestJobEventsAreStoredAndAcked(t *testing.T) {
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

	j, err := NewJobs(Params{Nc: nc, Js: js, Logger: logging.New(logging.Params{})})
	require.NoError(t, err)
	require.NoError(t, j.Start())
	t.Cleanup(func() { j.Stop() })

	job := messaging.NewJob(nc, "test.job", "Test")
	t.Cleanup(job.Close)
	job.Complete("done")

	ctx := context.Background()
	kv, err := js.KeyValue(ctx, BucketConfig.Bucket)
	require.NoError(t, err)
	require.Eventually(t, func() bool {
		_, err := kv.Get(ctx, "test.job")
		return err == nil
	}, 5*time.Second, 20*time.Millisecond)

	cons, err := js.Consumer(ctx, "SERAPH_JOBS", "SERAPH_JOBS")
	require.NoError(t, err)
	assert.Eventually(t, func() bool {
		info, err := cons.Info(ctx)
		return err == nil && info.NumAckPending == 0 && info.NumPending == 0
	}, 5*time.Second, 20*time.Millisecond)
}
