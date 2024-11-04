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
	"reflect"
	"time"

	"github.com/nats-io/nats.go"
)

const DefaultTimeout = 30 * time.Second

type RequestPayload interface {
	Marshal() ([]byte, error)
}

type ResponsePayload interface {
	Unmarshal(b []byte) error
}

func Request[Req RequestPayload, Res ResponsePayload](nc *nats.Conn, topic string, req Req, res Res) error {
	return RequestTimeout[Req, Res](nc, topic, DefaultTimeout, req, res)
}

func RequestVoid[Req RequestPayload](nc *nats.Conn, topic string, req Req) error {
	var v ResponsePayload = nil
	return RequestTimeout(nc, topic, DefaultTimeout, req, v)
}

func RequestVoidTimeout[Req RequestPayload](nc *nats.Conn, topic string, timeout time.Duration, req Req) error {
	var v ResponsePayload = nil
	return RequestTimeout(nc, topic, timeout, req, v)
}

func RequestTimeout[Req RequestPayload, Res ResponsePayload](nc *nats.Conn, topic string, timeout time.Duration, req Req, res Res) error {
	data, _ := req.Marshal()

	msg, err := nc.Request(topic, data, timeout)

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
