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
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"go.uber.org/fx"
	"umbasa.net/seraph/api-gateway/gateway-handler"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/jobs/jobs"
	"umbasa.net/seraph/logging"
)

var Module = fx.Module("jobs",
	fx.Provide(
		New,
	),
)

type Params struct {
	fx.In

	Log *logging.Logger
	Nc  *nats.Conn
	Js  jetstream.JetStream
}

type Result struct {
	fx.Out

	Handler gateway.GatewayHandler `group:"gatewayhandlers"`
}

type jobsHandler struct {
	logger *logging.Logger
	log    *slog.Logger
	kv     jetstream.KeyValue
}

type JobWithTimestamp struct {
	events.JobEvent
	Time time.Time `json:"time"`
}

func New(p Params) (Result, error) {
	kv, err := p.Js.CreateOrUpdateKeyValue(context.Background(), jobs.BucketConfig)
	if err != nil {
		return Result{}, err
	}

	return Result{
		Handler: &jobsHandler{
			logger: p.Log,
			log:    p.Log.GetLogger("preview"),
			kv:     kv,
		},
	}, nil
}

func (h *jobsHandler) Setup(app *gin.Engine, apiGroup *gin.RouterGroup) {
	apiGroup.GET("jobs", func(ctx *gin.Context) {
		watcher, err := h.kv.WatchAll(ctx)
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, err)
			return
		}
		defer watcher.Stop()

		values := make([]JobWithTimestamp, 0)
		for v := range watcher.Updates() {
			if v == nil {
				break
			}

			ev := events.JobEvent{}
			ev.Unmarshal(v.Value())

			values = append(values, JobWithTimestamp{
				JobEvent: ev,
				Time:     v.Created(),
			})
		}

		ctx.JSON(http.StatusOK, values)
	})
}
