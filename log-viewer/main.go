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

package main

import (
	"encoding/json"
	"fmt"

	"github.com/nats-io/nats.go"
	"go.uber.org/fx"
	"umbasa.net/seraph/messaging"
)

func main() {
	fx.New(
		messaging.Module,
		fx.Invoke(func(nc *nats.Conn) {
			nc.Subscribe("seraph.log", func(msg *nats.Msg) {
				var record map[string]any
				json.Unmarshal(msg.Data, &record)
				fmt.Printf("%v\n", record)
			})
		}),
	).Run()
}
