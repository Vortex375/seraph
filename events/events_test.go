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
