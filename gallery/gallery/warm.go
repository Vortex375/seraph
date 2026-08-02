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
	"encoding/json"
	"errors"
	"fmt"
	"sync"

	"github.com/nats-io/nats.go/jetstream"
	"go.mongodb.org/mongo-driver/bson"
	"umbasa.net/seraph/events"
)

// dispatchThumbnailWarm publishes a ThumbnailWarmRequest fire-and-forget
// onto the durable warm work queue for one physical (providerId, path) that
// just entered the read model - called from BOTH live ingestion
// (upsertPhoto, ingest.go) and backfill (backfillUpsert, backfill.go) so a
// photo gets a Thumbnail pre-generated in the background regardless of
// which route brought it into the gallery.
//
// This is a JetStream publish (durable, ack'd by the JetStream server that
// the message was persisted to the stream), never the thumbnailer's
// interactive core-NATS request/reply topic - see
// events.ThumbnailWarmRequest's docs for why: firing one request per photo
// through that path is exactly the failure this ticket exists to avoid.
// "Fire-and-forget" here means the caller does not wait for the thumbnailer
// to actually produce anything, not that delivery is unacknowledged -
// publishing to a stream still fails loudly (a returned error) if
// JetStream itself could not durably accept the message, and callers log
// that rather than letting it block or fail the ingest/backfill write it
// follows.
//
// A missing JetStream handle (g.js == nil, e.g. some unit tests that only
// exercise CRUD/query paths) makes this a no-op, mirroring every other
// JetStream-dependent seam in this package (see startIngestConsumer et al.).
func (g *GalleryProvider) dispatchThumbnailWarm(ctx context.Context, providerId string, filePath string) {
	if g.js == nil {
		return
	}

	req := events.ThumbnailWarmRequest{
		ProviderID: providerId,
		Path:       filePath,
	}
	data, err := json.Marshal(req)
	if err != nil {
		g.log.Error("failed to marshal ThumbnailWarmRequest", "error", err)
		return
	}

	if _, err := g.js.Publish(ctx, events.ThumbnailWarmTopic, data); err != nil {
		g.log.Error("failed to publish ThumbnailWarmRequest; this photo will not be pre-warmed until something else touches it",
			"providerId", providerId, "path", filePath, "error", err)
	}
}

// ensureThumbnailWarmStream creates (or updates) the durable JetStream work
// queue stream ThumbnailWarmRequest is published to, so dispatch works even
// if the thumbnailer service (which also creates/updates this same stream -
// see thumbnailer/thumbnailer/warm.go) has never run yet. Both sides
// declaring the same stream config is the same "either side may be first"
// convention events.FileChangedStream already uses between file-indexer and
// its consumers.
func (g *GalleryProvider) ensureThumbnailWarmStream(ctx context.Context) error {
	if g.js == nil {
		return nil
	}
	_, err := g.js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
		Name:      events.ThumbnailWarmStream,
		Subjects:  []string{events.ThumbnailWarmTopic},
		Retention: jetstream.WorkQueuePolicy,
	})
	if err != nil {
		return fmt.Errorf("create/update %s stream: %w", events.ThumbnailWarmStream, err)
	}
	return nil
}

// warmUnsupportedConsumerName is the durable JetStream consumer name the
// gallery service uses on events.ThumbnailWarmUnsupportedStream, following
// the same fixed-durable-name convention as every other durable consumer in
// this package.
const warmUnsupportedConsumerName = "SERAPH_GALLERY_WARM_UNSUPPORTED"

// startWarmUnsupportedConsumer creates (or reattaches to) the durable
// consumer that receives ThumbnailWarmUnsupportedNotice messages from the
// thumbnailer and records the reason against the corresponding gallery
// item - the "recording the reason means a message back to the gallery
// service" seam ticket 11 calls for.
func (g *GalleryProvider) startWarmUnsupportedConsumer(ctx context.Context) (*warmUnsupportedConsumer, error) {
	if g.js == nil {
		return nil, nil
	}

	streamCtx := context.Background()

	stream, err := g.js.CreateOrUpdateStream(streamCtx, jetstream.StreamConfig{
		Name:      events.ThumbnailWarmUnsupportedStream,
		Subjects:  []string{events.ThumbnailWarmUnsupportedTopic},
		Retention: jetstream.WorkQueuePolicy,
	})
	if err != nil {
		return nil, fmt.Errorf("create/update %s stream: %w", events.ThumbnailWarmUnsupportedStream, err)
	}

	cons, err := stream.CreateOrUpdateConsumer(streamCtx, jetstream.ConsumerConfig{
		Durable:   warmUnsupportedConsumerName,
		AckPolicy: jetstream.AckExplicitPolicy,
	})
	if err != nil {
		return nil, fmt.Errorf("create/update %s consumer: %w", warmUnsupportedConsumerName, err)
	}

	iter, err := cons.Messages()
	if err != nil {
		return nil, fmt.Errorf("start consuming %s: %w", warmUnsupportedConsumerName, err)
	}

	wc := &warmUnsupportedConsumer{
		g:    g,
		iter: iter,
	}

	g.wg.Add(1)
	go wc.loop(ctx, &g.wg)

	return wc, nil
}

type warmUnsupportedConsumer struct {
	g    *GalleryProvider
	iter jetstream.MessagesContext
}

func (wc *warmUnsupportedConsumer) stop() {
	if wc == nil {
		return
	}
	wc.iter.Stop()
}

func (wc *warmUnsupportedConsumer) loop(ctx context.Context, wg *sync.WaitGroup) {
	defer wg.Done()

	for {
		msg, err := wc.iter.Next()
		if errors.Is(err, jetstream.ErrMsgIteratorClosed) {
			return
		}
		if err != nil {
			wc.g.log.Error("thumbnail warm-unsupported consumer error", "error", err)
			return
		}

		wc.g.wg.Add(1)
		go func() {
			defer wc.g.wg.Done()
			wc.handleMessage(ctx, msg)
		}()
	}
}

func (wc *warmUnsupportedConsumer) handleMessage(ctx context.Context, msg jetstream.Msg) {
	g := wc.g

	notice := events.ThumbnailWarmUnsupportedNotice{}
	if err := json.Unmarshal(msg.Data(), &notice); err != nil {
		g.log.Error("failed to deserialize ThumbnailWarmUnsupportedNotice", "error", err)
		// malformed payload will never parse on redelivery either
		msg.Ack()
		return
	}

	if notice.ProviderID == "" || notice.Path == "" || notice.Reason == "" {
		g.log.Error("invalid ThumbnailWarmUnsupportedNotice: missing providerId, path or reason")
		msg.Ack()
		return
	}

	if err := g.recordUnsupported(ctx, notice.ProviderID, notice.Path, notice.Reason); err != nil {
		g.log.Error("failed to record unsupported reason from thumbnailer", "providerId", notice.ProviderID, "path", notice.Path, "error", err)
		// leave unacked so JetStream redelivers; the write below is a plain
		// idempotent $set, so redelivery is safe.
		return
	}

	msg.Ack()
}

// recordUnsupported writes Reason onto the galleryPhotos document at
// (providerId, filePath) as its Unsupported field, using the SAME
// UnsupportedReason* vocabulary ingestion's own decode failures already use
// (see photo_entities.go) - the thumbnailer's warm consumer maps its
// ErrorClass* values onto this vocabulary before sending the notice (see
// thumbnailer/thumbnailer/warm.go's unsupportedReasonFor) rather than the
// gallery service inventing a translation here.
//
// A document that no longer exists (e.g. the file was deleted between the
// warm request being dispatched and the thumbnailer answering) matches zero
// documents and is not an error: there is nothing to record the reason
// against any more.
//
// This deliberately does NOT go through withSequence/bump Seq: Unsupported
// here is a thumbnailer-observed corroboration of what ingestion's own
// decode already determined (see extractForEvent/extractMetadata), not new
// information that changes what a client viewing the delta feed needs to
// re-fetch - the item's displayable state was already established at
// ingest time.
func (g *GalleryProvider) recordUnsupported(ctx context.Context, providerId string, filePath string, reason string) error {
	filter := bson.M{"providerId": providerId, "path": filePath}
	update := bson.M{"$set": bson.M{"unsupported": reason}}
	_, err := g.photos.UpdateOne(ctx, filter, update)
	return err
}
