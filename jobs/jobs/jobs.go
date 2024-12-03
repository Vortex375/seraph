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
	"log/slog"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/spf13/viper"
	"go.mongodb.org/mongo-driver/mongo"
	"go.uber.org/fx"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/logging"
)

type Params struct {
	fx.In

	Nc     *nats.Conn
	Js     jetstream.JetStream
	Db     *mongo.Database
	Logger *logging.Logger
	Viper  *viper.Viper
	Mig    Migrations
}

type Jobs interface {
	Start() error
	Stop() error
}

type jobs struct {
	logger   *logging.Logger
	log      *slog.Logger
	nc       *nats.Conn
	js       jetstream.JetStream
	consumer jetstream.Consumer
	kv       jetstream.KeyValue

	ctx jetstream.ConsumeContext
}

func NewJobs(params Params) (Jobs, error) {
	log := params.Logger.GetLogger("jobs")

	log.Debug("create " + events.JobsStream)
	stream, err := params.Js.CreateOrUpdateStream(context.Background(), jetstream.StreamConfig{
		Name:              events.JobsStream,
		Subjects:          []string{events.JobsTopic},
		MaxMsgsPerSubject: 1,
	})
	if err != nil {
		return nil, err
	}

	consumer, err := stream.CreateOrUpdateConsumer(context.Background(), jetstream.ConsumerConfig{
		Durable: "SERAPH_JOBS",
	})
	if err != nil {
		return nil, err
	}

	kv, err := params.Js.CreateOrUpdateKeyValue(context.Background(), jetstream.KeyValueConfig{
		Bucket: "SERAPH_JOBS",
		TTL:    14 * 24 * time.Hour, // expire Jobs after 2 weeks TODO: make configurable!?
	})
	if err != nil {
		return nil, err
	}

	j := jobs{
		logger:   params.Logger,
		log:      log,
		nc:       params.Nc,
		js:       params.Js,
		consumer: consumer,
		kv:       kv,
	}

	return &j, nil
}

func (j *jobs) Start() error {
	var err error
	j.ctx, err = j.consumer.Consume(func(msg jetstream.Msg) {
		ev := events.JobEvent{}
		ev.Unmarshal(msg.Data())
		j.kv.Put(context.Background(), ev.Key, msg.Data())
		j.log.Debug("update "+ev.Key, "key", ev.Key, "description", ev.Description, "statusMessage", ev.StatusMessage)
	})
	return err
}

func (j *jobs) Stop() error {
	if j.ctx != nil {
		j.ctx.Drain()
		j.ctx = nil
	}

	return nil
}
