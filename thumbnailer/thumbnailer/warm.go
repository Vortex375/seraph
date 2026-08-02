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
	"encoding/json"
	"errors"
	"fmt"
	"sync"

	"github.com/nats-io/nats.go/jetstream"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/util"
)

// warmConsumerName is the durable JetStream consumer name the thumbnailer
// uses on events.ThumbnailWarmStream. Fixed and well-known, exactly like
// invalidationConsumerName, so the delivery position survives restarts.
const warmConsumerName = "SERAPH_THUMBNAILER_WARM"

// warmParallel bounds how many background warm requests are processed at
// once. This is a THIRD, independent concurrency budget - distinct from
// both the interactive preview limiter (Options.Parallel, capped at CPU
// count) and invalidationParallel - and deliberately smaller than either,
// so a large warm batch (a folder backfill of thousands of photos) can
// never monopolise every worker and an interactive preview request stays
// responsive while it runs. See TestWarmingDoesNotStarvePreviewPath.
const warmParallel = 1

// startWarmConsumer creates (or reattaches to) the durable warm-request
// consumer and begins processing ThumbnailWarmRequest messages in the
// background. It returns the running consumer so Stop() can drain it as
// part of the same shutdown sequence used for the preview request loop and
// the invalidation consumer.
func (t *Thumbnailer) startWarmConsumer(ctx context.Context) (*warmConsumer, error) {
	if t.js == nil {
		// no JetStream handle configured (e.g. some unit tests that only
		// exercise the preview path) - warming is simply not started.
		return nil, nil
	}

	streamCtx := context.Background()

	stream, err := t.js.CreateOrUpdateStream(streamCtx, jetstream.StreamConfig{
		Name:      events.ThumbnailWarmStream,
		Subjects:  []string{events.ThumbnailWarmTopic},
		Retention: jetstream.WorkQueuePolicy,
	})
	if err != nil {
		return nil, fmt.Errorf("create/update %s stream: %w", events.ThumbnailWarmStream, err)
	}

	cons, err := stream.CreateOrUpdateConsumer(streamCtx, jetstream.ConsumerConfig{
		Durable: warmConsumerName,
		// explicit ack: work must survive a thumbnailer restart and be
		// redelivered rather than lost - a message is only acked once
		// warming has actually completed, or is determined to be
		// permanently undecodable (see handleMessage).
		AckPolicy: jetstream.AckExplicitPolicy,
	})
	if err != nil {
		return nil, fmt.Errorf("create/update %s consumer: %w", warmConsumerName, err)
	}

	iter, err := cons.Messages()
	if err != nil {
		return nil, fmt.Errorf("start consuming %s: %w", warmConsumerName, err)
	}

	wc := &warmConsumer{
		t:       t,
		iter:    iter,
		limiter: util.NewLimiter(warmParallel),
	}

	t.wg.Add(1)
	go wc.loop(ctx, &t.wg)

	return wc, nil
}

type warmConsumer struct {
	t       *Thumbnailer
	iter    jetstream.MessagesContext
	limiter util.Limiter
}

func (wc *warmConsumer) stop() {
	if wc == nil {
		return
	}
	wc.iter.Stop()
}

// loop pulls warm requests off the durable consumer and dispatches each to
// its own goroutine. It deliberately does NOT itself acquire wc.limiter
// before dispatching: handleMessage's call into handleRequest already
// acquires/releases wc.limiter around the actual creation work (after the
// cheap "does a Thumbnail already exist" stat check, exactly like the
// interactive preview path's messageLoop/handleRequest split) - acquiring
// here too would double-acquire the same capacity-warmParallel limiter per
// message and deadlock once more messages are in flight than warmParallel
// allows.
func (wc *warmConsumer) loop(ctx context.Context, wg *sync.WaitGroup) {
	defer wg.Done()

	for {
		msg, err := wc.iter.Next()
		if errors.Is(err, jetstream.ErrMsgIteratorClosed) {
			return
		}
		if err != nil {
			wc.t.log.Error("thumbnail warm consumer error", "error", err)
			return
		}

		wc.t.wg.Add(1)
		go func() {
			defer wc.t.wg.Done()
			wc.handleMessage(ctx, msg)
		}()
	}
}

// handleMessage warms exactly one photo at the configured warm size
// (t.options.WarmSize), reusing the same handleRequest logic the
// interactive preview path uses - "thumbnail already exists" is a no-op
// success there too, which is what makes re-dispatching the same photo
// harmless (see TestRedispatchingSamePhotoIsHarmless).
//
// Ack policy:
//   - success (including "already existed"): ack.
//   - the source file cannot be decoded at all (unsupported format or
//     corrupt data): this can never succeed on redelivery either, so ack
//     rather than redeliver forever, and tell the publisher's read model
//     why (see reportUnsupported) so the reason is recorded rather than
//     the item silently never getting a Thumbnail with no trace of why.
//   - the source image decodes but exceeds the configured maximum
//     thumbnailable dimensions: also permanent (redelivery cannot change
//     the file), so ack; there is no matching entry in the read model's
//     "cannot decode" vocabulary for this (the file DID decode), so no
//     notice is sent - this is a thumbnailer policy limit, not a
//     statement about the photo's displayability.
//   - anything else (I/O error opening the source file, thumbnail storage
//     error): transient/infra failure - leave unacked so JetStream
//     redelivers. handleRequest is idempotent (id'd by content hash+size,
//     "already exists" short-circuits), so redelivery is always safe.
func (wc *warmConsumer) handleMessage(ctx context.Context, msg jetstream.Msg) {
	t := wc.t

	req := events.ThumbnailWarmRequest{}
	if err := json.Unmarshal(msg.Data(), &req); err != nil {
		t.log.Error("failed to deserialize ThumbnailWarmRequest", "error", err)
		// malformed payload will never parse on redelivery either
		msg.Ack()
		return
	}

	if req.ProviderID == "" || req.Path == "" {
		t.log.Error("invalid ThumbnailWarmRequest: empty providerId or path")
		msg.Ack()
		return
	}

	warmSize := t.options.WarmSize
	if warmSize == 0 {
		warmSize = DefaultWarmSize
	}

	resp := t.handleRequest(ctx, wc.limiter, ThumbnailRequest{
		ProviderID: req.ProviderID,
		Path:       req.Path,
		Width:      warmSize,
		Height:     warmSize,
		Exact:      true,
	})

	switch resp.ErrorClass {
	case ErrorClassUnsupportedFormat, ErrorClassCorrupt:
		t.log.Warn("photo cannot be decoded for warming; acking and reporting to owning read model",
			"provider", req.ProviderID, "path", req.Path, "errorClass", resp.ErrorClass, "error", resp.Error)
		wc.reportUnsupported(ctx, req, resp.ErrorClass)
		msg.Ack()
		return
	case ErrorClassTooLarge:
		// permanent for this file, but not a "cannot decode" outcome - see
		// handleMessage's docs. Ack without a notice.
		t.log.Warn("photo exceeds configured maximum thumbnailable size; acking without warming",
			"provider", req.ProviderID, "path", req.Path, "error", resp.Error)
		msg.Ack()
		return
	}

	if resp.Error != "" {
		// transient/infra failure (e.g. could not open the source file,
		// thumbnail storage error): leave unacked for redelivery.
		t.log.Error("failed to warm thumbnail; leaving unacked for redelivery",
			"provider", req.ProviderID, "path", req.Path, "error", resp.Error)
		return
	}

	msg.Ack()
}

// reportUnsupported publishes a ThumbnailWarmUnsupportedNotice fire-and-
// forget onto the durable ThumbnailWarmUnsupportedTopic queue, telling the
// publisher's read model that this photo could not be decoded and why - see
// events.ThumbnailWarmUnsupportedNotice's docs on why this is itself a
// durable queue and not a direct request/reply back to an unknown caller.
//
// Best-effort by design: if the publish itself fails, the warm message is
// still acked (see handleMessage) because retrying will not change whether
// the file decodes, and this consumer has no way to distinguish "which
// service published the original ThumbnailWarmRequest" beyond ProviderID/
// Path, which is exactly what the notice already carries.
func (wc *warmConsumer) reportUnsupported(ctx context.Context, req events.ThumbnailWarmRequest, errorClass string) {
	t := wc.t
	if t.js == nil {
		return
	}

	reason := unsupportedReasonFor(errorClass)

	notice := events.ThumbnailWarmUnsupportedNotice{
		ProviderID: req.ProviderID,
		Path:       req.Path,
		Reason:     reason,
	}
	data, err := json.Marshal(notice)
	if err != nil {
		t.log.Error("failed to marshal ThumbnailWarmUnsupportedNotice", "error", err)
		return
	}

	if _, err := t.js.Publish(ctx, events.ThumbnailWarmUnsupportedTopic, data); err != nil {
		t.log.Error("failed to publish ThumbnailWarmUnsupportedNotice", "provider", req.ProviderID, "path", req.Path, "error", err)
	}
}

// unsupportedReasonFor maps the thumbnailer's own ErrorClass* vocabulary to
// the gallery service's UnsupportedReason* vocabulary, reusing it rather
// than inventing a second one (see events.ThumbnailWarmUnsupportedNotice's
// docs). The thumbnailer package cannot import the gallery package (module
// boundary, and would be a layering inversion regardless), so the string
// values are duplicated here as raw literals; gallery/gallery/photo_entities.go
// documents these same two values as UnsupportedReasonFormat/
// UnsupportedReasonCorrupt.
func unsupportedReasonFor(errorClass string) string {
	switch errorClass {
	case ErrorClassUnsupportedFormat:
		return "format"
	case ErrorClassCorrupt:
		return "corrupt"
	default:
		return "corrupt"
	}
}
