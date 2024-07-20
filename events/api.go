package events

import (
	"github.com/hamba/avro/v2"

	_ "embed"
)

//go:embed schema.avsc
var schema string

var Schema avro.Schema

var Api avro.API

func init() {
	Schema = avro.MustParse(schema)

	Api = avro.Config{
		UnionResolutionError:       true,
		PartialUnionTypeResolution: false,
	}.Freeze()

	Api.Register("seraph.events.Event", Event{})
	Api.Register("seraph.events.FileInfoEvent", FileInfoEvent{})
	Api.Register("seraph.events.FileChangedEvent", FileChangedEvent{})
}
