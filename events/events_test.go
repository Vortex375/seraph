package events_test

import (
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/hamba/avro/v2"
	"github.com/stretchr/testify/assert"
	"umbasa.net/seraph/events"
)

func TestFileProviderEvent(t *testing.T) {
	input := events.FileInfoEvent{
		Event: events.Event{
			ID:      uuid.NewString(),
			Version: 2,
		},
		ProviderID: "testprovider",
		Path:       "testfile",
		Size:       14,
		Mode:       42,
		ModTime:    time.Now().Unix(),
		IsDir:      true,
	}

	doTest(t, events.Api, events.Schema, input, events.FileInfoEvent{})
}

func doTest(t *testing.T, api avro.API, schema avro.Schema, input any, output any) {
	data, err := api.Marshal(schema, input)

	if err != nil {
		t.Error(err)
	}

	err = api.Unmarshal(schema, data, &output)

	if err != nil {
		t.Error(err)
	}

	assert.Equal(t, input, output)
}
