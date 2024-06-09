package logging

import (
	"context"
	"encoding/json"
	"log/slog"

	"github.com/nats-io/nats.go"
)

type NatsHandler struct {
	nc     *nats.Conn
	attrs  []slog.Attr
	groups []string
}

func NewNatsHandler(nc *nats.Conn) *NatsHandler {
	return &NatsHandler{
		nc,
		make([]slog.Attr, 0),
		make([]string, 0),
	}
}

// implements slog.Handler
var _ slog.Handler = &NatsHandler{}

func (h *NatsHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return true
}

func (h *NatsHandler) Handle(ctx context.Context, r slog.Record) error {
	m := make(map[string]any)
	m["time"] = r.Time
	m["level"] = r.Level
	m["msg"] = r.Message

	recordAttrs := make([]slog.Attr, r.NumAttrs())
	r.Attrs(func(a slog.Attr) bool {
		recordAttrs = append(recordAttrs, a)
		return true
	})

	makeGroup(h.groups, recordAttrs, m)

	j, err := json.Marshal(m)

	if err != nil {
		return err
	}

	h.nc.Publish("seraph.log", j)

	return nil
}

func makeGroup(groups []string, attrs []slog.Attr, m map[string]any) {
	current := m
	for _, group := range groups {
		next, ok := current[group].(map[string]any)
		if !ok {
			next = make(map[string]any)
			current[group] = next
		}
		current = next
	}

	for _, attr := range attrs {
		key := attr.Key
		value := attr.Value.Resolve()

		if value.Kind() == slog.KindGroup {
			makeGroup([]string{key}, value.Group(), current)
		} else {
			current[key] = value.Any()
		}
	}
}

func (h *NatsHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	copy := *h
	copy.attrs = append(clone(h.attrs), attrs...)
	return &copy
}

func (h *NatsHandler) WithGroup(name string) slog.Handler {
	copy := *h
	copy.groups = append(clone(h.groups), name)
	return &copy
}

func clone[T any](s []T) []T {
	return append([]T{}, s...)
}
