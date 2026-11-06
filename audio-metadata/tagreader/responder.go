// Copyright © 2026 Benjamin Schmitz

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

package tagreader

import (
	"context"
	"log/slog"
	"sync"

	"github.com/nats-io/nats.go"
	"umbasa.net/seraph/audio-metadata/audiometadata"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
)

// parallel bounds how many requests are parsed at once, and with that how
// many provider-backed streams are open.
const parallel = 4

// Responder answers audiometadata.TagsRequestTopic and PictureRequestTopic.
type Responder struct {
	nc     *nats.Conn
	log    *slog.Logger
	reader *Reader
	sem    chan struct{}

	mu   sync.Mutex
	subs []*nats.Subscription
	wg   sync.WaitGroup
}

func NewResponder(nc *nats.Conn, logger *logging.Logger, reader *Reader) *Responder {
	return &Responder{
		nc:     nc,
		log:    logger.GetLogger("audiometadata"),
		reader: reader,
		sem:    make(chan struct{}, parallel),
	}
}

func (r *Responder) Start() error {
	for topic, handle := range map[string]func(context.Context, *nats.Msg){
		audiometadata.TagsRequestTopic:    r.handleTags,
		audiometadata.PictureRequestTopic: r.handlePicture,
	} {
		sub, err := r.nc.ChanQueueSubscribe(topic, topic, r.channel(handle))
		if err != nil {
			return err
		}
		r.mu.Lock()
		r.subs = append(r.subs, sub)
		r.mu.Unlock()
	}
	return nil
}

// Stop unsubscribes and waits for the in-flight requests.
func (r *Responder) Stop() error {
	r.mu.Lock()
	subs := r.subs
	r.subs = nil
	r.mu.Unlock()

	for _, sub := range subs {
		if err := sub.Unsubscribe(); err != nil {
			return err
		}
	}
	r.wg.Wait()
	return nil
}

func (r *Responder) channel(handle func(context.Context, *nats.Msg)) chan *nats.Msg {
	msgs := make(chan *nats.Msg, nats.DefaultSubPendingMsgsLimit)
	go func() {
		for msg := range msgs {
			r.wg.Add(1)
			go func() {
				defer r.wg.Done()
				r.sem <- struct{}{}
				defer func() { <-r.sem }()
				handle(messaging.ExtractTraceContext(context.Background(), msg), msg)
			}()
		}
	}()
	return msgs
}

func (r *Responder) handleTags(ctx context.Context, msg *nats.Msg) {
	req := audiometadata.TagsRequest{}
	var resp audiometadata.TagsResponse
	if err := req.Unmarshal(msg.Data); err != nil {
		resp.Error = "invalid tags request: " + err.Error()
	} else if req.ProviderID == "" || req.Path == "" {
		resp.Error = "invalid empty providerId or path"
	} else {
		resp = r.reader.Tags(ctx, req.ProviderID, req.Path)
	}
	if resp.Error != "" {
		r.log.Debug("tags request failed", "provider", req.ProviderID, "path", req.Path, "class", resp.ErrorClass, "error", resp.Error)
	}
	r.respond(msg, &resp)
}

func (r *Responder) handlePicture(ctx context.Context, msg *nats.Msg) {
	req := audiometadata.PictureRequest{}
	var resp audiometadata.PictureResponse
	if err := req.Unmarshal(msg.Data); err != nil {
		resp.Error = "invalid picture request: " + err.Error()
	} else if req.ProviderID == "" || req.Path == "" {
		resp.Error = "invalid empty providerId or path"
	} else {
		resp = r.reader.Picture(ctx, req.ProviderID, req.Path, req.Offset, int(req.Length))
	}
	if resp.Error != "" {
		r.log.Debug("picture request failed", "provider", req.ProviderID, "path", req.Path, "class", resp.ErrorClass, "error", resp.Error)
	}
	r.respond(msg, &resp)
}

func (r *Responder) respond(msg *nats.Msg, resp interface{ Marshal() ([]byte, error) }) {
	data, err := resp.Marshal()
	if err != nil {
		r.log.Error("error encoding response", "error", err)
		return
	}
	if err := msg.Respond(data); err != nil {
		r.log.Error("error sending response", "error", err)
	}
}
