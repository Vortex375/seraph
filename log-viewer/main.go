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

package main

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/fatih/color"
	"github.com/nats-io/nats.go"
	"go.uber.org/fx"
	"umbasa.net/seraph/messaging"
)

func main() {
	fx.New(
		messaging.Module,
		fx.Invoke(func(nc *nats.Conn, lc fx.Lifecycle) {
			lc.Append(fx.StartHook(func() {
				nc.Subscribe("seraph.log", func(msg *nats.Msg) {
					var record map[string]any
					json.Unmarshal(msg.Data, &record)
					time, err := time.Parse(time.RFC3339Nano, record["time"].(string))
					var timeStr string
					if err == nil {
						timeStr = time.Format("2006-01-02 15:04:05.999")
					} else {
						timeStr = record["time"].(string)
					}

					color.New(color.FgWhite).Print(timeStr)
					printLvl(record["level"].(string))
					color.New(color.FgCyan).Print(record["component"].(string))
					fmt.Print(" ")
					fmt.Print(record["msg"])
					attrColor := color.New(color.FgWhite).Add(color.Faint)
					attrColor.Print(" (")
					first := true
					for key, val := range record {
						if key == "time" || key == "level" || key == "msg" || key == "component" || key == "" {
							continue
						}

						if !first {
							fmt.Print(" ")
						} else {
							first = false
						}
						attrColor.Printf("%s=%v", key, val)
					}
					attrColor.Print(")")
					fmt.Println()
				})
			}))
		}),
	).Run()
}

func printLvl(level string) {
	switch level {
	case "DEBUG":
		color.New(color.FgYellow).Print(" DEBUG ")
	case "INFO":
		color.New(color.FgGreen).Print(" INFO ")
	case "WARN":
		color.New(color.FgYellow).Add(color.Bold).Print(" WARN ")
	case "ERROR":
		color.New(color.FgRed).Add(color.Bold).Print(" ERROR ")
	default:
		fmt.Print(" " + level + " ")
	}
}
