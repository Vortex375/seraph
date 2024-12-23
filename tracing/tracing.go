package tracing

import (
	"context"
	"log/slog"

	"github.com/spf13/viper"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/exporters/stdout/stdouttrace"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"go.opentelemetry.io/otel/trace"
	"go.opentelemetry.io/otel/trace/noop"
	"go.uber.org/fx"
	"umbasa.net/seraph/logging"
)

var Module = fx.Module("tracing",
	fx.Provide(
		NewTracing,
	),
)

type TracingParams struct {
	fx.In

	Log   *logging.Logger
	Viper *viper.Viper
	Lc    fx.Lifecycle
}

type TracingResult struct {
	fx.Out

	Tracing *Tracing
}

type Tracing struct {
	TracerProvider trace.TracerProvider
	Propagator     propagation.TextMapPropagator

	ctx    context.Context
	cancel context.CancelFunc
}

func NewTracing(p TracingParams) (TracingResult, error) {
	log := p.Log.GetLogger("tracing")
	ctx, cancel := context.WithCancel(context.Background())

	tracerProvider, err := newTracerProvider(ctx, log, p.Viper)
	if err != nil {
		cancel()
		return TracingResult{}, err
	}

	propagator := newPropagator()

	tracing := Tracing{
		TracerProvider: tracerProvider,
		Propagator:     propagator,
		ctx:            ctx,
		cancel:         cancel,
	}

	p.Lc.Append(fx.StopHook(func(ctx context.Context) error {
		tracing.cancel()
		if tracer, ok := tracerProvider.(*sdktrace.TracerProvider); ok {
			return tracer.Shutdown(ctx)
		}
		return nil
	}))

	return TracingResult{
		Tracing: &tracing,
	}, nil
}

func newTracerProvider(ctx context.Context, log *slog.Logger, v *viper.Viper) (trace.TracerProvider, error) {
	enabled := v.GetBool("tracing.enabled")
	if !enabled {
		log.Info("tracing disabled")
		return noop.NewTracerProvider(), nil
	}

	opts := make([]sdktrace.TracerProviderOption, 0)

	stdOutEnabled := v.GetBool("tracing.stdOut")
	if stdOutEnabled {
		log.Info("exporting traces to stdout")
		stdOutExporter, err := stdouttrace.New(
			stdouttrace.WithPrettyPrint())
		if err != nil {
			return nil, err
		}
		opts = append(opts, sdktrace.WithBatcher(stdOutExporter))
	}

	grpcUrl := v.GetString("tracing.otlp.grpc")
	if grpcUrl != "" {
		log.Info("exporting traces via OTLP/gRPC", "url", grpcUrl)
		exporter, err := otlptracegrpc.New(ctx, otlptracegrpc.WithEndpoint(grpcUrl), otlptracegrpc.WithInsecure())
		if err != nil {
			return nil, err
		}
		opts = append(opts, sdktrace.WithBatcher(exporter))
	}

	serviceName := v.GetString("tracing.serviceName")
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
	opts = append(opts, sdktrace.WithResource(res))

	tracerProvider := sdktrace.NewTracerProvider(opts...)

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
