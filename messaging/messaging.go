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
