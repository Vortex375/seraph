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
	// var request []slog.Attr
	// var response []slog.Attr
	var other = make([]slog.Attr, 0)

	r.Attrs(func(attr slog.Attr) bool {
		if attr.Key == "component" {
			component = attr.Value.String()
		} else if attr.Key == "error" {
			err = attr.Value.String()
		} else if attr.Key == "stack" || attr.Key == "stacktrace" {
			if attr.Value.Kind() == slog.KindGroup {
				for _, stackTraceAttr := range attr.Value.Group() {
					stack += stackTraceAttr.Value.String() + "\n"
				}
			} else {
				stack = attr.Value.String()
			}
			// } else if attr.Key == "request" && attr.Value.Kind() == slog.KindGroup {
			// 	request = attr.Value.Group()
			// } else if attr.Key == "response" && attr.Value.Kind() == slog.KindGroup {
			// 	response = attr.Value.Group()
		} else {
			other = append(other, attr)
		}
		return true
	})

	for _, attr := range h.attrs {
		if attr.Key == "component" {
			component = attr.Value.String()
		} else {
			other = append(other, attr)
		}
	}

	timeColor.Print(r.Time.Format("2006-01-02 15:04:05.999 "))
	levelColor(r.Level).Print(r.Level.String())
	fmt.Print(" ")
	if component != "" {
		componentColor.Print(component)
		fmt.Print(" ")
	}
	fmt.Print(r.Message)
	if len(other) > 0 {
		fmt.Print(" ")
		attrColor.Print(other)
	}
	fmt.Print("\n")
	if err != "" {
		errorDetailLabelColor.Print("ERR")
		fmt.Print(" ")
		errorDetailColor.Print(err)
		fmt.Print("\n")
	}
	if stack != "" {
		if r.Level >= slog.LevelError {
			errorDetailLabelColor.Print("AT")
			fmt.Print(" ")
			errorDetailColor.Print(stack)
		} else {
			fmt.Print("at ", stack)
		}
		fmt.Print("\n")
	}

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
