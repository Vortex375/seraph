package logging

import "log/slog"

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
			val := value.Any()
			if e, ok := val.(error); ok {
				current[key] = e.Error()
			} else {
				current[key] = value.Any()
			}
		}
	}
}

func clone[T any](s []T) []T {
	return append([]T{}, s...)
}
