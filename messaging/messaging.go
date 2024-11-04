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
	"sync/atomic"

	"github.com/nats-io/nats.go"
	"github.com/spf13/viper"
	"go.uber.org/fx"
)

var Module = fx.Module("messaging",
	fx.Provide(
		NewNats,
		NewJetStream,
	),
	fx.Supply(&NatsHolder{}),
)

type NatsHolder struct {
	nc atomic.Value
}

func (h *NatsHolder) Get() *nats.Conn {
	v := h.nc.Load()
	if v == nil {
		return nil
	}
	return v.(*nats.Conn)
}

type Params struct {
	fx.In

	Holder *NatsHolder
	Viper  *viper.Viper `optional:"true"`
}

type Result struct {
	Nc *nats.Conn
}

func NewNats(p Params, lc fx.Lifecycle) (*nats.Conn, error) {
	url := nats.DefaultURL
	if p.Viper != nil {
		configUrl := p.Viper.GetString("nats.url")
		if configUrl != "" {
			url = configUrl
		}
	}

	closeChan := make(chan bool)
	conn, err := nats.Connect(url, nats.ClosedHandler(func(*nats.Conn) {
		close(closeChan)
	}))

	if err == nil {
		lc.Append(fx.StopHook(func() {
			conn.Drain()
			<-closeChan
		}))
	}

	p.Holder.nc.Store(conn)

	return conn, err
}
