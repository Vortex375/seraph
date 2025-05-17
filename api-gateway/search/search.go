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

package search

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"go.uber.org/fx"
	"umbasa.net/seraph/api-gateway/auth"
	"umbasa.net/seraph/api-gateway/gateway-handler"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/logging"
)

var Module = fx.Module("search",
	fx.Provide(
		New,
	),
)

type Params struct {
	fx.In

	Log  *logging.Logger
	Nc   *nats.Conn
	Auth auth.Auth
}

type Result struct {
	fx.Out

	Handler gateway.GatewayHandler `group:"gatewayhandlers"`
}

type searchHandler struct {
	log  *slog.Logger
	nc   *nats.Conn
	auth auth.Auth
}

const searchAckTime = 3 * time.Second
const searchReplyTime = 30 * time.Second

func New(p Params) Result {
	return Result{
		Handler: &searchHandler{
			log:  p.Log.GetLogger("shares"),
			nc:   p.Nc,
			auth: p.Auth,
		},
	}
}

func (h *searchHandler) Setup(app *gin.Engine, apiGroup *gin.RouterGroup, publicApiGroup *gin.RouterGroup) {
	apiGroup.GET("/search", func(ctx *gin.Context) {
		query := ctx.Query("q")

		ctx.Header("Content-Type", "application/x-ndjson")

		if query == "" {
			ctx.Status(200)
			return
		}

		requestId := uuid.NewString()

		ackChan := make(chan *nats.Msg, nats.DefaultSubPendingMsgsLimit)
		replyChan := make(chan *nats.Msg, nats.DefaultSubPendingMsgsLimit)

		ackSub, err := h.nc.ChanSubscribe(fmt.Sprintf(events.SearchAckTopicPattern, requestId), ackChan)
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, err)
			return
		}
		defer ackSub.Unsubscribe()
		replySub, err := h.nc.ChanSubscribe(fmt.Sprintf(events.SearchReplyTopicPattern, requestId), replyChan)
		if err != nil {
			ctx.AbortWithError(http.StatusInternalServerError, err)
			return
		}
		defer replySub.Unsubscribe()

		searchRequest := events.SearchRequest{
			RequestId: requestId,
			UserId:    h.auth.GetUserId(ctx.Request.Context()),
			Query:     query,
			Types:     []string{events.SearchTypeFiles},
		}
		data, _ := json.Marshal(searchRequest)
		h.nc.Publish(events.SearchRequestTopic, data)

		ctx.Status(200)
		ctx.Writer.WriteHeaderNow()
		activeReplies := map[string]struct{}{}
		startTs := time.Now()
		for {
			select {
			case msg := <-ackChan:
				ack := events.SearchAck{}
				json.Unmarshal(msg.Data, &ack)
				if ack.Ack {
					activeReplies[ack.ReplyId] = struct{}{}
				}
			case msg := <-replyChan:
				reply := events.SearchReply{}
				json.Unmarshal(msg.Data, &reply)
				if reply.Last {
					delete(activeReplies, reply.ReplyId)
					if len(activeReplies) == 0 && time.Since(startTs) > searchAckTime {
						return
					}
				} else {
					activeReplies[reply.ReplyId] = struct{}{}
					ctx.Writer.Write(msg.Data)
					ctx.Writer.WriteString("\n")
					ctx.Writer.Flush()
				}
			case <-searchTimeout(len(activeReplies)):
				return
			}
		}
	})

}

func searchTimeout(numReplies int) <-chan time.Time {
	if numReplies == 0 {
		return time.After(searchAckTime)
	} else {
		return time.After(searchReplyTime)
	}
}
