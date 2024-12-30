package messaging

import (
	"context"

	"github.com/nats-io/nats.go"
	"go.opentelemetry.io/otel/propagation"
)

func ExtractTraceContext(ctx context.Context, msg *nats.Msg) context.Context {
	propagator := propagation.TraceContext{}
	return propagator.Extract(ctx, propagation.HeaderCarrier(msg.Header))
}

func InjectTraceContext(ctx context.Context, header nats.Header) nats.Header {
	propagator := propagation.TraceContext{}
	propagator.Inject(ctx, propagation.HeaderCarrier(header))
	return header
}
