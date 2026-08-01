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

package thumbnailer

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path"
	"sync"

	"github.com/nats-io/nats.go/jetstream"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/util"
)

// invalidationConsumerName is the durable JetStream consumer name the
// thumbnailer uses on events.FileChangedStream. It is a fixed, well-known
// name (rather than derived from fileProviderId/path) so that the consumer's
// delivery position survives restarts: JetStream durables are looked up by
// name, and a durable that isn't recreated with the same name starts over
// from scratch, losing exactly the "cleaned up while we were down" guarantee
// this ticket requires.
const invalidationConsumerName = "SERAPH_THUMBNAILER_INVALIDATION"

// invalidationParallel bounds how many file-change cleanups run at once.
// This is intentionally a separate, small limiter from the one guarding
// interactive thumbnail creation (t.limiter / Options.Parallel): cleanup is
// background housekeeping and must never be able to starve out capacity
// needed to answer a preview request. Keeping the two limiters distinct
// makes that property structural rather than something that has to be
// re-verified by inspecting scheduling order.
const invalidationParallel = 2

// startInvalidationConsumer creates (or reattaches to) the durable
// file-change consumer and begins processing FileChangedEvent messages in
// the background. It returns the running consumer so Stop() can drain it as
// part of the same shutdown sequence used for the preview request loop.
func (t *Thumbnailer) startInvalidationConsumer(ctx context.Context) (*invalidationConsumer, error) {
	if t.js == nil {
		// no JetStream handle configured (e.g. some unit tests that only
		// exercise the preview path) - invalidation is simply not started.
		return nil, nil
	}

	streamCtx := context.Background()

	stream, err := t.js.CreateOrUpdateStream(streamCtx, jetstream.StreamConfig{
		Name:     events.FileChangedStream,
		Subjects: []string{events.FileChangedTopic},
	})
	if err != nil {
		return nil, fmt.Errorf("create/update %s stream: %w", events.FileChangedStream, err)
	}

	cons, err := stream.CreateOrUpdateConsumer(streamCtx, jetstream.ConsumerConfig{
		Durable: invalidationConsumerName,
		// explicit ack: a crash or redelivery must not silently drop a
		// cleanup - the message is only acked once cleanup has actually
		// completed (see invalidationConsumer.handleMessage).
		AckPolicy: jetstream.AckExplicitPolicy,
	})
	if err != nil {
		return nil, fmt.Errorf("create/update %s consumer: %w", invalidationConsumerName, err)
	}

	iter, err := cons.Messages()
	if err != nil {
		return nil, fmt.Errorf("start consuming %s: %w", invalidationConsumerName, err)
	}

	ic := &invalidationConsumer{
		t:       t,
		iter:    iter,
		limiter: util.NewLimiter(invalidationParallel),
	}

	t.wg.Add(1)
	go ic.loop(ctx, &t.wg)

	return ic, nil
}

type invalidationConsumer struct {
	t       *Thumbnailer
	iter    jetstream.MessagesContext
	limiter util.Limiter
}

func (ic *invalidationConsumer) stop() {
	if ic == nil {
		return
	}
	// Stop() unblocks iter.Next() with jetstream.ErrMsgIteratorClosed,
	// letting the loop goroutine exit; the caller (Thumbnailer.Stop) joins
	// it and any in-flight handlers via t.wg.Wait().
	ic.iter.Stop()
}

func (ic *invalidationConsumer) loop(ctx context.Context, wg *sync.WaitGroup) {
	defer wg.Done()

	for {
		msg, err := ic.iter.Next()
		if errors.Is(err, jetstream.ErrMsgIteratorClosed) {
			return
		}
		if err != nil {
			ic.t.log.Error("file-change consumer error", "error", err)
			return
		}

		if !ic.limiter.Begin(ctx) {
			// shutting down
			return
		}

		ic.t.wg.Add(1)
		go func() {
			defer ic.t.wg.Done()
			defer ic.limiter.End()
			ic.handleMessage(ctx, msg)
		}()
	}
}

func (ic *invalidationConsumer) handleMessage(ctx context.Context, msg jetstream.Msg) {
	t := ic.t

	ev := events.FileChangedEvent{}
	if err := ev.Unmarshal(msg.Data()); err != nil {
		t.log.Error("failed to deserialize FileChangedEvent", "error", err)
		// malformed payload will never parse on redelivery either; ack it
		// rather than retrying forever.
		msg.Ack()
		return
	}

	switch ev.Change {
	case events.FileChangedEventDeleted, events.FileChangedEventChanged:
		if err := t.invalidateThumbnails(ctx, ev.ProviderID, ev.Path); err != nil {
			t.log.Error("failed to invalidate thumbnails for file change", "provider", ev.ProviderID, "path", ev.Path, "change", ev.Change, "error", err)
			// leave unacked so JetStream redelivers; handler is idempotent
			return
		}
	default:
		// "created" and any future event kinds require no thumbnail
		// invalidation - a newly created file cannot yet have a stale
		// Thumbnail.
	}

	msg.Ack()
}

// invalidateThumbnails removes every Thumbnail that could have been created
// for (providerId, filePath) at any of the known thumbnail sizes.
//
// Thumbnail storage is a flat folder keyed by a hash of (providerId, path)
// plus the requested width/height, with no way to enumerate "all thumbnails
// for this file" other than trying each size combination a non-exact
// request could have produced (see fitSize/ThumbnailSizes). Most attempts
// return not-found, which is expected and not an error: a file that never
// had Thumbnails at a given size must not produce any log noise.
func (t *Thumbnailer) invalidateThumbnails(ctx context.Context, providerId string, filePath string) error {
	hash := ThumbnailHash(path.Join(providerId, filePath))

	var firstErr error
	for _, width := range ThumbnailSizes {
		for _, height := range ThumbnailSizes {
			thumbName := fmt.Sprintf("%s_%dx%d.jpg", hash, width, height)
			err := t.thumbnailStorage.RemoveAll(ctx, path.Join(t.path, thumbName))
			if err == nil || errors.Is(err, os.ErrNotExist) {
				continue
			}
			t.log.Error("error removing thumbnail", "provider", providerId, "path", filePath, "thumbnail", thumbName, "error", err)
			if firstErr == nil {
				firstErr = err
			}
		}
	}

	return firstErr
}
