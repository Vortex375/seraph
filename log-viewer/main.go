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
