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

package logging

import (
	"encoding/json"
	"log/slog"

	"go.uber.org/fx"
	"go.uber.org/fx/fxevent"
	"umbasa.net/seraph/messaging"
)

var Module = fx.Module("logger",
	fx.Provide(
		New,
	),
)

type Logger struct {
	natsHolder *messaging.NatsHolder
	levelVar   *slog.LevelVar
}

func (l *Logger) SetLevel(level slog.Level) {
	l.levelVar.Set(level)
}

type Params struct {
	fx.In

	NatsHolder *messaging.NatsHolder `optional:"true"`
}

func FxLogger() fx.Option {
	return fx.WithLogger(func(logger *Logger) fxevent.Logger {
		return &fxevent.SlogLogger{Logger: logger.GetLogger("fx")}
	})
}

func New(p Params) *Logger {
	levelVar := slog.LevelVar{}
	levelVar.Set(slog.LevelInfo)
	return &Logger{p.NatsHolder, &levelVar}
}

func (l *Logger) GetLogger(name string) *slog.Logger {
	var handlers []slog.Handler
	if l.natsHolder == nil {
		handlers = []slog.Handler{
			NewConsoleHandler(l.levelVar),
		}
	} else {
		handlers = []slog.Handler{
			NewConsoleHandler(l.levelVar),
			NewNatsHandler(l.natsHolder),
		}
	}
	return slog.New(NewHandlerMux(handlers...)).With("component", name)
}

type jsonValue struct {
	v any
}

func JsonValue(v any) slog.LogValuer {
	return &jsonValue{v}
}

func (v *jsonValue) LogValue() slog.Value {
	data, err := json.Marshal(v.v)
	if err != nil {
		return slog.AnyValue(v.v)
	}
	return slog.StringValue(string(data))
}
