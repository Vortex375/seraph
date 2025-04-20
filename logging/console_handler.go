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
	"fmt"
	"log/slog"
	"net/http"
	"strings"

	"github.com/fatih/color"
)

var timeColor = color.New(color.FgWhite)
var componentColor = color.New(color.FgCyan)
var attrColor = color.New(color.FgWhite).Add(color.Faint)

var debugColor = color.New(color.FgYellow)
var infoColor = color.New(color.FgGreen)
var warnColor = color.New(color.FgYellow, color.Bold)
var errorColor = color.New(color.FgRed, color.Bold)
var errorDetailLabelColor = color.New(color.BgRed)
var errorDetailColor = color.New(color.FgRed)

func levelColor(level slog.Level) *color.Color {
	switch {
	case level >= slog.LevelError:
		return errorColor
	case level >= slog.LevelWarn:
		return warnColor
	case level >= slog.LevelInfo:
		return infoColor
	default:
		return debugColor
	}
}

// for HTTP status codes
var informationalColor = color.New(color.BgBlue)
var okColor = color.New(color.BgGreen)
var redirectColor = color.New(color.BgMagenta)
var clientErrorColor = color.New(color.BgYellow)
var serverErrorColor = color.New(color.BgRed)

func statusColor(status int) *color.Color {
	switch {
	case status >= http.StatusInternalServerError:
		return serverErrorColor
	case status >= http.StatusBadRequest:
		return clientErrorColor
	case status >= http.StatusMultipleChoices:
		return redirectColor
	case status >= http.StatusOK:
		return okColor
	case status >= http.StatusContinue:
		return informationalColor
	}
	return color.New()
}

type ConsoleHandler struct {
	level  slog.Leveler
	attrs  []slog.Attr
	groups []string
}

func NewConsoleHandler(level slog.Leveler) *ConsoleHandler {
	return &ConsoleHandler{
		level,
		make([]slog.Attr, 0),
		make([]string, 0),
	}
}

// implements slog.Handler
var _ slog.Handler = &ConsoleHandler{}

func (h *ConsoleHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return level >= h.level.Level()
}

func (h *ConsoleHandler) Handle(ctx context.Context, r slog.Record) error {
	if r.Level < h.level.Level() {
		return nil
	}

	var component string
	var err string
	var stack string
	var request []slog.Attr
	var response []slog.Attr
	var other = make([]slog.Attr, 0)

	r.Attrs(func(attr slog.Attr) bool {
		value := attr.Value.Resolve()
		if attr.Key == "component" {
			component = value.String()
		} else if attr.Key == "error" {
			err = value.String()
		} else if attr.Key == "stack" || attr.Key == "stacktrace" {
			if value.Kind() == slog.KindGroup {
				for _, stackTraceAttr := range value.Group() {
					stack += stackTraceAttr.Value.Resolve().String() + "\n"
				}
			} else {
				stack = value.String()
			}
		} else if attr.Key == "request" && value.Kind() == slog.KindGroup {
			request = value.Group()
			other = append(other, attr)
		} else if attr.Key == "response" && value.Kind() == slog.KindGroup {
			response = value.Group()
			other = append(other, attr)
		} else {
			other = append(other, attr)
		}
		return true
	})

	for _, attr := range h.attrs {
		if attr.Key == "component" {
			component = attr.Value.Resolve().String()
		} else {
			other = append(other, attr)
		}
	}

	w := strings.Builder{}

	timeColor.Fprint(&w, r.Time.Format("2006-01-02 15:04:05.999 "))
	levelColor(r.Level).Fprint(&w, r.Level.String())
	fmt.Fprint(&w, " ")

	if component != "" {
		componentColor.Fprint(&w, component)
		fmt.Fprint(&w, " ")
	}

	if response != nil {
		fmt.Fprint(&w, "| ")
		status := getAttr(response, "status")
		if status != nil {
			statusColor(int(status.Value.Int64())).Fprint(&w, status.Value)
			fmt.Fprint(&w, " | ")
		}
		latency := getAttr(response, "latency")
		if latency != nil {
			fmt.Fprint(&w, latency.Value)
			fmt.Fprint(&w, " | ")
		}
	}

	if request != nil {
		method := getAttr(request, "method")
		if method != nil {
			fmt.Fprint(&w, method.Value)
			fmt.Fprint(&w, " | ")
		}
		path := getAttr(request, "path")
		if path != nil {
			fmt.Fprint(&w, path.Value)
			fmt.Fprint(&w, " | ")
		}
	}

	fmt.Fprint(&w, r.Message)

	if len(other) > 0 {
		attrColor.Fprint(&w, " (")
		for i, attr := range other {
			if i > 0 {
				attrColor.Fprint(&w, " ")
			}
			attrColor.Fprint(&w, attr.Key)
			attrColor.Fprint(&w, "=")
			attrColor.Fprint(&w, attr.Value.Resolve().String())
		}
		attrColor.Fprint(&w, ")")
	}
	fmt.Fprint(&w, "\n")

	if err != "" {
		errorDetailLabelColor.Fprint(&w, "ERR")
		fmt.Fprint(&w, " ")
		errorDetailColor.Fprint(&w, err)
		fmt.Fprint(&w, "\n")
	}

	if stack != "" {
		if r.Level >= slog.LevelError {
			errorDetailLabelColor.Fprint(&w, "AT")
			fmt.Fprint(&w, " ")
			errorDetailColor.Fprint(&w, stack)
		} else {
			fmt.Fprint(&w, "at ", stack)
		}
		fmt.Fprint(&w, "\n")
	}

	fmt.Print(w.String())

	return nil
}

func (h *ConsoleHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	copy := *h
	copy.attrs = append(clone(h.attrs), attrs...)
	return &copy
}

func (h *ConsoleHandler) WithGroup(name string) slog.Handler {
	copy := *h
	copy.groups = append(clone(h.groups), name)
	return &copy
}

func getAttr(attrs []slog.Attr, key string) *slog.Attr {
	for _, attr := range attrs {
		if attr.Key == key {
			return &attr
		}
	}
	return nil
}
