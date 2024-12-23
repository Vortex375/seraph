package tracing

import (
	"context"

	"github.com/spf13/viper"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/stdout/stdouttrace"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	"go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.17.0"
	"go.uber.org/fx"
)

var Module = fx.Module("tracing",
	fx.Provide(
		NewTracing,
	),
)

type TracingParams struct {
	fx.In

	Viper *viper.Viper
	Lc    fx.Lifecycle
}

type TracingResult struct {
	fx.Out

	Tracing Tracing
}

type Tracing struct {
	TracerProvider *trace.TracerProvider
	Propagator     propagation.TextMapPropagator
}

func NewTracing(p TracingParams) (TracingResult, error) {
	tracerProvider, err := newTracerProvider(p.Viper)
	if err != nil {
		return TracingResult{}, err
	}

	propagator := newPropagator()

	tracing := Tracing{
		TracerProvider: tracerProvider,
		Propagator:     propagator,
	}

	p.Lc.Append(fx.StopHook(func(ctx context.Context) error {
		return tracerProvider.Shutdown(ctx)
	}))

	return TracingResult{
		Tracing: tracing,
	}, nil
}

func newTracerProvider(v *viper.Viper) (*trace.TracerProvider, error) {
	stdOutExporter, err := stdouttrace.New(
		stdouttrace.WithPrettyPrint())
	if err != nil {
		return nil, err
	}

	serviceName := v.GetString("serviceName")

	res, err := resource.Merge(
		resource.Default(),
		resource.NewWithAttributes(
			semconv.SchemaURL,
			semconv.ServiceName(serviceName),
		),
	)
	if err != nil {
		return nil, err
	}

	tracerProvider := trace.NewTracerProvider(
		trace.WithBatcher(stdOutExporter),
		trace.WithResource(res),
	)

	// register default
	otel.SetTracerProvider(tracerProvider)

	return tracerProvider, nil
}

func newPropagator() propagation.TextMapPropagator {
	propagator := propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	)

	otel.SetTextMapPropagator(propagator)

	return propagator
}
