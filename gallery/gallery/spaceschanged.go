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
	"context"
	"errors"
	"fmt"
	"sync"

	"github.com/nats-io/nats.go/jetstream"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"umbasa.net/seraph/entities"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/spaces/spaces"
)

// spacesChangedConsumerName is the durable JetStream consumer name the
// gallery service uses on events.SpaceChangedStream, following the same
// fixed-durable-name convention as ingestConsumerName and the thumbnailer's
// invalidationConsumerName: a durable that isn't recreated under the same
// name starts over from the beginning of the stream, which would defeat the
// point of durability across restarts.
const spacesChangedConsumerName = "SERAPH_GALLERY_SPACES_CHANGED"

// startSpacesChangedConsumer creates (or reattaches to) the durable
// spaces.changed consumer and begins reacting to SpaceChangedEvent messages
// in the background. This is the ingestion prefix cache's invalidation
// signal (see prefixCache/refreshPrefixCache in ingest.go): without it, a
// Space re-pointed at a different File Provider, or one that becomes
// inaccessible or is deleted, leaves the cache correct only until the next
// ADD or restart.
func (g *GalleryProvider) startSpacesChangedConsumer(ctx context.Context) (*spacesChangedConsumer, error) {
	if g.js == nil {
		// no JetStream handle configured (e.g. some unit tests that only
		// exercise the CRUD/query paths) - invalidation is simply not
		// started, exactly like startIngestConsumer.
		return nil, nil
	}

	streamCtx := context.Background()

	stream, err := g.js.CreateOrUpdateStream(streamCtx, jetstream.StreamConfig{
		Name:     events.SpaceChangedStream,
		Subjects: []string{events.SpaceChangedTopic},
	})
	if err != nil {
		return nil, fmt.Errorf("create/update %s stream: %w", events.SpaceChangedStream, err)
	}

	cons, err := stream.CreateOrUpdateConsumer(streamCtx, jetstream.ConsumerConfig{
		Durable:   spacesChangedConsumerName,
		AckPolicy: jetstream.AckExplicitPolicy,
	})
	if err != nil {
		return nil, fmt.Errorf("create/update %s consumer: %w", spacesChangedConsumerName, err)
	}

	iter, err := cons.Messages()
	if err != nil {
		return nil, fmt.Errorf("start consuming %s: %w", spacesChangedConsumerName, err)
	}

	sc := &spacesChangedConsumer{
		g:    g,
		iter: iter,
	}

	g.wg.Add(1)
	go sc.loop(ctx, &g.wg)

	return sc, nil
}

type spacesChangedConsumer struct {
	g    *GalleryProvider
	iter jetstream.MessagesContext
}

func (sc *spacesChangedConsumer) stop() {
	if sc == nil {
		return
	}
	sc.iter.Stop()
}

func (sc *spacesChangedConsumer) loop(ctx context.Context, wg *sync.WaitGroup) {
	defer wg.Done()

	for {
		msg, err := sc.iter.Next()
		if errors.Is(err, jetstream.ErrMsgIteratorClosed) {
			return
		}
		if err != nil {
			sc.g.log.Error("spaces.changed consumer error", "error", err)
			return
		}

		sc.g.wg.Add(1)
		go func() {
			defer sc.g.wg.Done()
			sc.handleMessage(ctx, msg)
		}()
	}
}

func (sc *spacesChangedConsumer) handleMessage(ctx context.Context, msg jetstream.Msg) {
	g := sc.g

	ev := events.SpaceChangedEvent{}
	if err := ev.Unmarshal(msg.Data()); err != nil {
		g.log.Error("failed to deserialize SpaceChangedEvent", "error", err)
		// malformed payload will never parse on redelivery either
		msg.Ack()
		return
	}

	ctx, span := g.tracer.Start(ctx, "handleSpaceChanged")
	defer span.End()

	if err := g.reactToSpaceChanged(ctx, ev.SpaceID); err != nil {
		g.log.Error("failed to react to spaces.changed event", "error", err, "spaceId", ev.SpaceID)
		// leave unacked so JetStream redelivers - refreshing the prefix
		// cache is idempotent (it always replaces the set outright), so
		// redelivery is safe.
		return
	}

	msg.Ack()
}

// reactToSpaceChanged is spaces.changed's handler: it decides, as cheaply as
// possible, whether the affected Space is one any configured Gallery Source
// Folder references, and if so re-resolves the whole ingestion prefix cache
// so a re-pointed Space is followed to its new physical location, a Space
// that lost a user is dropped, and a deleted Space's folders become
// harmlessly unresolvable rather than pinned to a stale physical prefix.
//
// The event (see events.SpaceChangedEvent) carries only the Space's id and
// the kind of change, not its current fileProviders - so "does any folder
// reference this Space" is answered by reading the Space back through
// spaces.crud (the same RPC spaces.GetSpacesForUser uses) and checking
// whether any of its fileProviders.spaceProviderId values match a configured
// folder. That read is a single small request/reply plus one Mongo query
// over the (typically tiny) configured-folder set - far cheaper than a
// SpaceResolveRequest per configured folder, which is what a full refresh
// costs and is exactly what this function exists to avoid paying for a
// Space nothing references.
//
// A "deleted" change is the one case that read cannot resolve: the Space
// document is already gone by the time the event arrives, so its
// fileProviders can no longer be looked up. There is no cheaper option that
// stays correct - the deleted Space's spaceProviderId(s) are unknowable at
// this point - so a full refresh runs unconditionally for "deleted". This is
// no more expensive than what ADD already pays on every folder addition, and
// deletions are rare, administrator-driven events, not a per-event hot path.
func (g *GalleryProvider) reactToSpaceChanged(ctx context.Context, spaceId string) error {
	referenced, err := g.spaceIsReferenced(ctx, spaceId)
	if err != nil {
		return err
	}
	if !referenced {
		return nil
	}

	return g.refreshPrefixCache(ctx)
}

// spaceIsReferenced reports whether any configured Gallery Source Folder's
// SpaceProviderId belongs to the Space identified by spaceId, so
// reactToSpaceChanged knows whether a refresh is worth its cost.
//
// A transient failure to read the Space back is reported as an error, not
// folded into either boolean outcome: the caller lets the JetStream message
// go unacked so it is redelivered and retried, exactly like ingest.go's
// handleMessage does for its own transient failures - that is a truer
// recovery than guessing "referenced" and possibly still leaving the cache
// stale if the guess later turns out to be wrong.
//
// A Space that no longer exists (the "deleted" case: the document is
// already gone by the time this runs) is the one case that is NOT an error:
// it always reports referenced=true, because "no, it is definitely not
// referenced" cannot be established once the Space's fileProviders are
// unrecoverable, and the safe default is to pay for a refresh rather than
// silently leave the cache pinned to a deleted Space's stale prefix.
func (g *GalleryProvider) spaceIsReferenced(ctx context.Context, spaceId string) (bool, error) {
	proto := entities.MakePrototype(&spaces.SpacePrototype{})
	id, err := primitive.ObjectIDFromHex(spaceId)
	if err != nil {
		// not a valid id at all: cannot possibly match a real Space, and
		// nothing a refresh would fix
		return false, nil
	}
	proto.Id.Set(id)

	req := spaces.SpaceCrudRequest{
		Operation: "READ",
		Space:     proto,
	}
	res := spaces.SpaceCrudResponse{}
	if err := messaging.Request(ctx, g.nc, spaces.SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res)); err != nil {
		return false, fmt.Errorf("while reading space %s to react to spaces.changed: %w", spaceId, err)
	}
	if res.Error != "" {
		return false, fmt.Errorf("while reading space %s to react to spaces.changed: %s", spaceId, res.Error)
	}
	if len(res.Space) == 0 {
		// Space no longer exists (deleted) - see the "deleted" case in the
		// docs above: always treat as referenced.
		return true, nil
	}

	spaceProviderIds := make(map[string]bool, len(res.Space[0].FileProviders))
	for _, fp := range res.Space[0].FileProviders {
		spaceProviderIds[fp.SpaceProviderId] = true
	}
	if len(spaceProviderIds) == 0 {
		return false, nil
	}

	ids := make([]string, 0, len(spaceProviderIds))
	for id := range spaceProviderIds {
		ids = append(ids, id)
	}

	count, err := g.sourceFolders.CountDocuments(ctx, bson.M{"spaceProviderId": bson.M{"$in": ids}})
	if err != nil {
		return true, fmt.Errorf("while checking for gallery source folders referencing space %s: %w", spaceId, err)
	}

	return count > 0, nil
}
