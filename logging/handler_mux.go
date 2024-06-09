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
