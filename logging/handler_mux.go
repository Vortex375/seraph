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
	"context"
	"log/slog"
)

type HandlerMux struct {
	Handlers []slog.Handler
}

func NewHandlerMux(handlers ...slog.Handler) *HandlerMux {
	return &HandlerMux{handlers}
}

// implements slog.Handler
var _ slog.Handler = &HandlerMux{}

func (h *HandlerMux) Enabled(ctx context.Context, level slog.Level) bool {
	enabled := false
	for _, handler := range h.Handlers {
		enabled = enabled || handler.Enabled(ctx, level)
	}
	return enabled
}

func (h *HandlerMux) Handle(ctx context.Context, r slog.Record) error {
	for _, handler := range h.Handlers {
		err := handler.Handle(ctx, r)
		if err != nil {
			return err
		}
	}
	return nil
}

func (h *HandlerMux) WithAttrs(attrs []slog.Attr) slog.Handler {
	copy := HandlerMux{make([]slog.Handler, len(h.Handlers))}
	for i, handler := range h.Handlers {
		copy.Handlers[i] = handler.WithAttrs(attrs)
	}
	return &copy
}

func (h *HandlerMux) WithGroup(name string) slog.Handler {
	copy := HandlerMux{make([]slog.Handler, len(h.Handlers))}
	for i, handler := range h.Handlers {
		copy.Handlers[i] = handler.WithGroup(name)
	}
	return &copy
}
