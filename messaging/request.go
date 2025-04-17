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
	"context"
	"encoding/json"
	"reflect"
	"time"

	"github.com/nats-io/nats.go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/trace"
)

const DefaultTimeout = 30 * time.Second

type RequestPayload interface {
	Marshal() ([]byte, error)
}

type ResponsePayload interface {
	Unmarshal(b []byte) error
}

type JsonPayload struct {
	v any
}

func (p *JsonPayload) Marshal() ([]byte, error) {
	return json.Marshal(p.v)
}

func (p *JsonPayload) Unmarshal(b []byte) error {
	return json.Unmarshal(b, p.v)
}

func Json(v any) *JsonPayload {
	return &JsonPayload{v}
}

func Request[Req RequestPayload, Res ResponsePayload](ctx context.Context, nc *nats.Conn, topic string, req Req, res Res) error {
	return RequestTimeout(ctx, nc, topic, DefaultTimeout, req, res)
}

func RequestVoid[Req RequestPayload](ctx context.Context, nc *nats.Conn, topic string, req Req) error {
	var v ResponsePayload = nil
	return RequestTimeout(ctx, nc, topic, DefaultTimeout, req, v)
}

func RequestVoidTimeout[Req RequestPayload](ctx context.Context, nc *nats.Conn, topic string, timeout time.Duration, req Req) error {
	var v ResponsePayload = nil
	return RequestTimeout(ctx, nc, topic, timeout, req, v)
}

func RequestTimeout[Req RequestPayload, Res ResponsePayload](ctx context.Context, nc *nats.Conn, topic string, timeout time.Duration, req Req, res Res) error {
	tracer := otel.Tracer("request")
	if tracer != nil {
		var span trace.Span
		ctx, span = tracer.Start(ctx, "request "+topic)
		defer span.End()
	}

	data, err := req.Marshal()
	if err != nil {
		return err
	}

	header := InjectTraceContext(ctx, make(nats.Header))

	msg, err := nc.RequestMsg(&nats.Msg{
		Subject: topic,
		Header:  header,
		Data:    data,
	}, timeout)
	if err != nil {
		return err
	}

	rv := reflect.ValueOf(res)
	if !rv.IsValid() || rv.IsNil() {
		return nil
	}

	err = res.Unmarshal(msg.Data)

	return err
}
