// Copyright © 2024 Benjamin Schmitz

// This file is part of Seraph.

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
	"github.com/nats-io/nats.go"
	"go.uber.org/fx"
)

var Module = fx.Module("messaging",
	fx.Provide(
		NewNats,
	),
)

func NewNats(lc fx.Lifecycle) (*nats.Conn, error) {
	closeChan := make(chan bool)
	conn, err := nats.Connect(nats.DefaultURL, nats.ClosedHandler(func(*nats.Conn) {
		close(closeChan)
	}))

	if err == nil {
		lc.Append(fx.StopHook(func() {
			conn.Drain()
			<-closeChan
		}))
	}

	return conn, err
}
