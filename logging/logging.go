package logging

import (
	"log/slog"
	"os"

	"github.com/nats-io/nats.go"
	"go.uber.org/fx"
)

var Module = fx.Module("logger",
	fx.Provide(
		New,
	),
)

type Logger struct {
	nc       *nats.Conn
	levelVar *slog.LevelVar
}

func (l *Logger) SetLevel(level slog.Level) {
	l.levelVar.Set(level)
}

type Params struct {
	fx.In

	Nc *nats.Conn `optional:"true"`
}

func New(p Params) *Logger {
	levelVar := slog.LevelVar{}
	levelVar.Set(slog.LevelInfo)
	return &Logger{p.Nc, &levelVar}
}

func (l *Logger) GetLogger(name string) *slog.Logger {
	var handlers []slog.Handler
	if l.nc == nil {
		handlers = []slog.Handler{
			slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
				Level: l.levelVar,
			}),
		}
	} else {
		handlers = []slog.Handler{
			slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{
				Level: l.levelVar,
			}),
			NewNatsHandler(l.nc),
		}
	}
	return slog.New(NewHandlerMux(handlers...)).With("component", name)
}
