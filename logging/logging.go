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

package logging

import (
	"log/slog"
	"os"

	"go.uber.org/fx"
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

func New(p Params) *Logger {
	levelVar := slog.LevelVar{}
	levelVar.Set(slog.LevelInfo)
	return &Logger{p.NatsHolder, &levelVar}
}

func (l *Logger) GetLogger(name string) *slog.Logger {
	var handlers []slog.Handler
	if l.natsHolder == nil {
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
			NewNatsHandler(l.natsHolder),
		}
	}
	return slog.New(NewHandlerMux(handlers...)).With("component", name)
}
