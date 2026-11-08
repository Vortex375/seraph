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

package gallery

import (
	"log/slog"
	"testing"

	"github.com/nats-io/nats.go/jetstream"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"umbasa.net/seraph/events"
)

type fakeMsg struct {
	jetstream.Msg
	data  []byte
	acked bool
}

func (m *fakeMsg) Data() []byte { return m.data }
func (m *fakeMsg) Ack() error   { m.acked = true; return nil }

// An event must not be acked - and so dropped - before the source folders
// could be loaded even once: an empty prefix set then means "unknown".
func TestEventsHeldUntilPrefixCacheLoaded(t *testing.T) {
	g := &GalleryProvider{log: slog.Default(), prefixCache: newPrefixCache()}
	ic := &ingestConsumer{g: g}

	data, err := (&events.FileChangedEvent{
		ProviderID: "physical-photos",
		Change:     events.FileChangedEventCreated,
		Path:       "/photos/a.jpg",
	}).Marshal()
	require.NoError(t, err)

	msg := &fakeMsg{data: data}
	ic.handleMessage(t.Context(), msg)
	assert.False(t, msg.acked, "event acked before the prefix cache was loaded")

	// loaded, and the event is for no configured folder: dropping it is right
	g.prefixCache.set(nil)
	ic.handleMessage(t.Context(), msg)
	assert.True(t, msg.acked)
}
