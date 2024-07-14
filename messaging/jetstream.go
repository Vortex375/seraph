package messaging

import (
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"go.uber.org/fx"
)

type JetStreamParams struct {
	fx.In

	Nc *nats.Conn
}

type JetStreamResult struct {
	fx.Out

	Js jetstream.JetStream
}

func NewJetStream(p JetStreamParams) (JetStreamResult, error) {
	js, err := jetstream.New(p.Nc)

	return JetStreamResult{Js: js}, err
}
