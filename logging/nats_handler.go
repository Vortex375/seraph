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
	"context"
	"encoding/json"
	"log/slog"

	"umbasa.net/seraph/messaging"
)

type NatsHandler struct {
	holder *messaging.NatsHolder
	attrs  []slog.Attr
	groups []string
}

func NewNatsHandler(holder *messaging.NatsHolder) *NatsHandler {
	return &NatsHandler{
		holder,
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
	nc := h.holder.Get()
	if nc == nil {
		return nil
	}

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

	nc.Publish("seraph.log", j)

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
