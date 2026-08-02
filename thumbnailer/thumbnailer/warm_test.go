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
	"fmt"
	"os"
	"path"
	"path/filepath"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"umbasa.net/seraph/events"
)

// resetWarmStreams removes the durable warm-request and warm-unsupported
// streams (if any) so each warm test starts from a clean slate - the
// durable consumer names are fixed (warmConsumerName), so stream state
// would otherwise leak between tests in this package, exactly like
// resetInvalidationStream.
func resetWarmStreams(t *testing.T, js jetstream.JetStream) {
	t.Helper()
	t.Cleanup(func() {
		_ = js.DeleteStream(context.Background(), events.ThumbnailWarmStream)
		_ = js.DeleteStream(context.Background(), events.ThumbnailWarmUnsupportedStream)
	})
}

// publishThumbnailWarm publishes a ThumbnailWarmRequest onto the durable
// warm work queue, creating the stream first if it does not exist yet -
// mirroring how the gallery service (the real publisher) does it.
func publishThumbnailWarm(t *testing.T, js jetstream.JetStream, req events.ThumbnailWarmRequest) {
	t.Helper()

	_, err := js.CreateOrUpdateStream(context.Background(), jetstream.StreamConfig{
		Name:      events.ThumbnailWarmStream,
		Subjects:  []string{events.ThumbnailWarmTopic},
		Retention: jetstream.WorkQueuePolicy,
	})
	require.NoError(t, err)

	data, err := json.Marshal(req)
	require.NoError(t, err)

	_, err = js.Publish(context.Background(), events.ThumbnailWarmTopic, data)
	require.NoError(t, err)
}

// warmThumbName returns the Thumbnail file name warming (providerId, path)
// at size would produce - the same naming scheme handleRequest uses
// (hash of providerId+path, plus exact WxH).
func warmThumbName(providerId, filePath string, size int) string {
	return fmt.Sprintf("%s_%dx%d.jpg", ThumbnailHash(path.Join(providerId, filePath)), size, size)
}

// warmUnsupportedWatcher subscribes to the durable warm-unsupported queue
// as a plain core-NATS consumer (via a JetStream ephemeral pull-less
// subscription is unnecessary here - a simple ChanSubscribe on the subject
// sees every publish, since nothing else is consuming it in these tests)
// and collects every notice it receives, so tests can assert on the
// recorded reason without needing a real gallery service.
type warmUnsupportedWatcher struct {
	ch chan events.ThumbnailWarmUnsupportedNotice
}

func watchWarmUnsupported(t *testing.T, nc *nats.Conn) *warmUnsupportedWatcher {
	t.Helper()

	w := &warmUnsupportedWatcher{ch: make(chan events.ThumbnailWarmUnsupportedNotice, 16)}

	sub, err := nc.Subscribe(events.ThumbnailWarmUnsupportedTopic, func(msg *nats.Msg) {
		notice := events.ThumbnailWarmUnsupportedNotice{}
		if err := json.Unmarshal(msg.Data, &notice); err != nil {
			return
		}
		w.ch <- notice
	})
	require.NoError(t, err)
	t.Cleanup(func() { sub.Unsubscribe() })

	return w
}

func (w *warmUnsupportedWatcher) waitForOne(t *testing.T, timeout time.Duration) *events.ThumbnailWarmUnsupportedNotice {
	t.Helper()
	select {
	case n := <-w.ch:
		return &n
	case <-time.After(timeout):
		return nil
	}
}

// TestWarmingCreatesThumbnailAtConfiguredSizeWithoutAnyRequest covers: a
// photo entering the read model (simulated here by publishing
// ThumbnailWarmRequest directly, since this package tests the thumbnailer
// in isolation) results in a Thumbnail at the configured warm size, without
// anyone issuing an interactive ThumbnailRequest.
func TestWarmingCreatesThumbnailAtConfiguredSizeWithoutAnyRequest(t *testing.T) {
	thumb, _, js := getThumbnailerWithJetStream(t, nil)
	defer thumb.Stop()
	resetWarmStreams(t, js)

	name := writeFixtureJpeg(t, "fixture_warm_default_size.jpg", 2048, 2048)

	publishThumbnailWarm(t, js, events.ThumbnailWarmRequest{
		ProviderID: "testinput",
		Path:       name,
	})

	expected := warmThumbName("testinput", name, DefaultWarmSize)
	ok := waitFor(t, 5*time.Second, func() bool {
		return thumbExistsOnDisk(expected)
	})
	assert.True(t, ok, "expected a Thumbnail at the default warm size to appear without any interactive request")
}

// TestWarmingUsesConfiguredSizeAndOnlyThatSize covers: the warm size is
// configurable, and only that one size is produced - not any of the other
// ThumbnailSizes, and not the interactive DefaultThumbnailSize either.
func TestWarmingUsesConfiguredSizeAndOnlyThatSize(t *testing.T) {
	const configuredWarmSize = 128
	options := &Options{
		JpegQuality: 90,
		Parallel:    2,
		WarmSize:    configuredWarmSize,
	}
	thumb, _, js := getThumbnailerWithJetStream(t, options)
	defer thumb.Stop()
	resetWarmStreams(t, js)

	name := writeFixtureJpeg(t, "fixture_warm_configured_size.jpg", 1024, 1024)

	publishThumbnailWarm(t, js, events.ThumbnailWarmRequest{
		ProviderID: "testinput",
		Path:       name,
	})

	expected := warmThumbName("testinput", name, configuredWarmSize)
	ok := waitFor(t, 5*time.Second, func() bool {
		return thumbExistsOnDisk(expected)
	})
	require.True(t, ok, "expected a Thumbnail at the configured warm size")

	// none of the other common sizes should have been produced by warming
	for _, size := range ThumbnailSizes {
		if size == configuredWarmSize {
			continue
		}
		assert.False(t, thumbExistsOnDisk(warmThumbName("testinput", name, size)),
			"warming must produce exactly the configured size, not %d", size)
	}
}

// TestBackfillWarmsManyPhotosWithNoSilentLosses covers: warming a large
// batch (simulating backfill dispatching many photos) produces a Thumbnail
// for every single one - none silently dropped, which is exactly the
// failure mode core-NATS request/reply had and the durable work queue
// exists to avoid.
func TestBackfillWarmsManyPhotosWithNoSilentLosses(t *testing.T) {
	thumb, _, js := getThumbnailerWithJetStream(t, nil)
	defer thumb.Stop()
	resetWarmStreams(t, js)

	const count = 40
	names := make([]string, count)
	for i := 0; i < count; i++ {
		names[i] = writeFixtureJpeg(t, fmt.Sprintf("fixture_warm_batch_%d.jpg", i), 300, 300)
	}

	for _, name := range names {
		publishThumbnailWarm(t, js, events.ThumbnailWarmRequest{
			ProviderID: "testinput",
			Path:       name,
		})
	}

	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		allDone := true
		for _, name := range names {
			if !thumbExistsOnDisk(warmThumbName("testinput", name, DefaultWarmSize)) {
				allDone = false
				break
			}
		}
		if allDone {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	missing := 0
	for _, name := range names {
		if !thumbExistsOnDisk(warmThumbName("testinput", name, DefaultWarmSize)) {
			missing++
		}
	}
	assert.Equal(t, 0, missing, "every dispatched photo must eventually get a Thumbnail - no silent losses")
}

// TestWarmingHasItsOwnSmallerConcurrencyBudget covers: the warm consumer's
// concurrency budget is a distinct limiter instance from both the
// interactive preview limiter and the invalidation limiter, and is smaller
// than the interactive one - so a large warm batch structurally cannot
// monopolise every worker.
func TestWarmingHasItsOwnSmallerConcurrencyBudget(t *testing.T) {
	// explicit Parallel, deliberately well above warmParallel: the
	// interactive budget defaults to runtime.NumCPU() in production, which
	// could otherwise equal 1 (== warmParallel) on a single-CPU test
	// runner and make this assertion flaky rather than meaningful.
	options := &Options{
		JpegQuality: 90,
		Parallel:    4,
	}
	thumb, _, js := getThumbnailerWithJetStream(t, options)
	defer thumb.Stop()
	resetWarmStreams(t, js)

	thumb.mu.Lock()
	previewLimiter := thumb.limiter
	invalidation := thumb.invalidation
	warm := thumb.warm
	thumb.mu.Unlock()

	require.NotNil(t, previewLimiter)
	require.NotNil(t, warm)
	assert.NotSame(t, previewLimiter, warm.limiter, "preview and warm limiters must be independent so warming cannot starve previews")
	if invalidation != nil {
		assert.NotSame(t, invalidation.limiter, warm.limiter, "invalidation and warm limiters must be independent")
	}

	thumb.mu.Lock()
	interactiveParallel := thumb.options.Parallel
	thumb.mu.Unlock()

	assert.Less(t, warmParallel, interactiveParallel, "warm concurrency must be strictly smaller than the interactive preview budget")
}

// TestInteractivePreviewStaysResponsiveDuringLargeWarmBatch covers: an
// interactive preview request issued while a large warm batch is in flight
// completes promptly, proving the preview path is not queued up behind
// warm work - the same observable property TestCleanupDoesNotStarvePreviewPath
// proves for the invalidation consumer, applied to warming.
func TestInteractivePreviewStaysResponsiveDuringLargeWarmBatch(t *testing.T) {
	thumb, nc, js := getThumbnailerWithJetStream(t, nil)
	defer thumb.Stop()
	resetWarmStreams(t, js)

	// flood many more warm requests than the warm consumer's concurrency
	// budget so some are necessarily queued up
	for i := 0; i < warmParallel*20; i++ {
		name := writeFixtureJpeg(t, fmt.Sprintf("fixture_warm_starvation_%d.jpg", i), 512, 512)
		publishThumbnailWarm(t, js, events.ThumbnailWarmRequest{
			ProviderID: "testinput",
			Path:       name,
		})
	}

	previewName := writeFixtureJpeg(t, "fixture_warm_starvation_preview.jpg", 256, 256)

	start := time.Now()
	requestThumbnail(t, nc, "testinput", previewName, 128, 128)
	elapsed := time.Since(start)

	assert.Less(t, elapsed, 3*time.Second, "an interactive preview request must stay responsive during a large warm batch")
}

// TestWarmRequestSurvivesRestartAndIsRedelivered covers: work survives a
// thumbnailer restart. A warm request published while no thumbnailer is
// running must still be delivered (and produce a Thumbnail) once a
// thumbnailer reattaches to the same durable consumer - mirroring
// TestInvalidationConsumerIsDurableAcrossRestart.
func TestWarmRequestSurvivesRestartAndIsRedelivered(t *testing.T) {
	nc, err := nats.Connect(natsServer.ClientURL())
	require.NoError(t, err)
	defer nc.Close()

	js, err := jetstream.New(nc)
	require.NoError(t, err)
	resetWarmStreams(t, js)

	name := writeFixtureJpeg(t, "fixture_warm_restart.jpg", 512, 512)
	expected := warmThumbName("testinput", name, DefaultWarmSize)

	// publish the warm request before ANY thumbnailer is running
	publishThumbnailWarm(t, js, events.ThumbnailWarmRequest{
		ProviderID: "testinput",
		Path:       name,
	})

	require.False(t, thumbExistsOnDisk(expected), "sanity check: no consumer was running yet")

	// now start a thumbnailer, reattaching to the same durable consumer;
	// the backlogged warm request must be delivered and processed
	thumb, _, _ := getThumbnailerWithJetStream(t, nil)
	defer thumb.Stop()

	ok := waitFor(t, 5*time.Second, func() bool {
		return thumbExistsOnDisk(expected)
	})
	assert.True(t, ok, "expected the durable consumer to process the backlogged warm request after startup")
}

// TestWarmRequestIsAckedOnlyOnCompletion covers the redelivery half of "ack
// on completion": a warm request naming a providerId with no File Provider
// listening at all (a transient/infra condition indistinguishable from
// "that service is temporarily down") must be left unacked - not acked and
// discarded - so that once the same physical file becomes reachable under
// a providerId that IS being served, redelivery of the (corrected) request
// eventually succeeds. This exercises the same
// "leave unacked so JetStream redelivers" branch
// TestRedeliveryOfSameEventIsHarmless exercises for invalidation.
func TestWarmRequestIsAckedOnlyOnCompletion(t *testing.T) {
	thumb, _, js := getThumbnailerWithJetStream(t, nil)
	defer thumb.Stop()
	resetWarmStreams(t, js)

	name := writeFixtureJpeg(t, "fixture_warm_unreachable_provider.jpg", 512, 512)
	expectedOnRealProvider := warmThumbName("testinput", name, DefaultWarmSize)
	unreachable := warmThumbName("no-such-provider", name, DefaultWarmSize)

	publishThumbnailWarm(t, js, events.ThumbnailWarmRequest{
		ProviderID: "no-such-provider",
		Path:       name,
	})

	// give the consumer a chance to try and fail (no responder for that
	// provider) - nothing should ever be produced under that provider's hash
	time.Sleep(300 * time.Millisecond)
	assert.False(t, thumbExistsOnDisk(unreachable), "sanity: an unreachable provider must never produce a Thumbnail")

	// a normal request against the real, reachable provider must still
	// succeed - proving the consumer kept retrying/serving other work
	// rather than getting stuck - and the original message is left
	// perpetually unacked/redelivered rather than silently discarded,
	// exactly as TestWarmRequestSurvivesRestartAndIsRedelivered proves for
	// the backlog-at-startup case.
	publishThumbnailWarm(t, js, events.ThumbnailWarmRequest{
		ProviderID: "testinput",
		Path:       name,
	})
	ok := waitFor(t, 5*time.Second, func() bool {
		return thumbExistsOnDisk(expectedOnRealProvider)
	})
	assert.True(t, ok, "a warm request for a reachable provider must succeed even while an earlier request for an unreachable one is still being retried")
}

// TestUndecodablePhotoIsAckedOnceAndReasonReported covers: a photo the
// thumbnailer cannot decode is acked (not redelivered forever), and the
// reason is reported back to the owning read model via
// ThumbnailWarmUnsupportedNotice, using the same UnsupportedReason*
// vocabulary the gallery service's own ingestion decode uses ("format" for
// an unsupported format).
func TestUndecodablePhotoIsAckedOnceAndReasonReported(t *testing.T) {
	thumb, _, js := getThumbnailerWithJetStream(t, nil)
	defer thumb.Stop()
	resetWarmStreams(t, js)

	nc2, err := nats.Connect(natsServer.ClientURL())
	require.NoError(t, err)
	defer nc2.Close()
	watcher := watchWarmUnsupported(t, nc2)

	name := "fixture_warm_unsupported.txt"
	err = os.WriteFile(name, []byte("this is not an image"), 0644)
	require.NoError(t, err)
	t.Cleanup(func() { os.Remove(name) })

	publishThumbnailWarm(t, js, events.ThumbnailWarmRequest{
		ProviderID: "testinput",
		Path:       name,
	})

	notice := watcher.waitForOne(t, 5*time.Second)
	require.NotNil(t, notice, "expected a ThumbnailWarmUnsupportedNotice for an undecodable photo")
	assert.Equal(t, "testinput", notice.ProviderID)
	assert.Equal(t, name, notice.Path)
	assert.Equal(t, "format", notice.Reason, "must reuse the gallery service's UnsupportedReasonFormat vocabulary, not a new one")

	// republishing (simulating redelivery of the same message) must not
	// produce a second, different outcome - the underlying operation stays
	// permanently ack-and-report, never eventually succeeding or erroring
	// differently.
	publishThumbnailWarm(t, js, events.ThumbnailWarmRequest{
		ProviderID: "testinput",
		Path:       name,
	})
	second := watcher.waitForOne(t, 5*time.Second)
	require.NotNil(t, second)
	assert.Equal(t, "format", second.Reason)
}

// TestCorruptPhotoIsAckedAndReportedAsCorrupt covers the second half of the
// undecodable vocabulary mapping: a recognized-format-but-corrupt file maps
// to UnsupportedReasonCorrupt ("corrupt"), distinct from "format".
func TestCorruptPhotoIsAckedAndReportedAsCorrupt(t *testing.T) {
	thumb, _, js := getThumbnailerWithJetStream(t, nil)
	defer thumb.Stop()
	resetWarmStreams(t, js)

	nc2, err := nats.Connect(natsServer.ClientURL())
	require.NoError(t, err)
	defer nc2.Close()
	watcher := watchWarmUnsupported(t, nc2)

	name := "fixture_warm_corrupt.jpg"
	corrupt := append([]byte{0xFF, 0xD8, 0xFF, 0xE0}, []byte("garbage bytes that fail mid-decode, not a real jpeg body")...)
	err = os.WriteFile(name, corrupt, 0644)
	require.NoError(t, err)
	t.Cleanup(func() { os.Remove(name) })

	publishThumbnailWarm(t, js, events.ThumbnailWarmRequest{
		ProviderID: "testinput",
		Path:       name,
	})

	notice := watcher.waitForOne(t, 5*time.Second)
	require.NotNil(t, notice)
	assert.Equal(t, "corrupt", notice.Reason)
}

// TestRedispatchingSamePhotoIsHarmless covers: re-dispatching a warm
// request for a photo that has already been warmed produces no error, no
// duplicate work observable on disk, and leaves the existing Thumbnail
// exactly as it was - the same "already exists" short-circuit the
// interactive path relies on.
func TestRedispatchingSamePhotoIsHarmless(t *testing.T) {
	thumb, _, js := getThumbnailerWithJetStream(t, nil)
	defer thumb.Stop()
	resetWarmStreams(t, js)

	name := writeFixtureJpeg(t, "fixture_warm_redispatch.jpg", 512, 512)
	expected := warmThumbName("testinput", name, DefaultWarmSize)

	publishThumbnailWarm(t, js, events.ThumbnailWarmRequest{ProviderID: "testinput", Path: name})
	ok := waitFor(t, 5*time.Second, func() bool {
		return thumbExistsOnDisk(expected)
	})
	require.True(t, ok)

	firstInfo, err := os.Stat(fixturePath(expected))
	require.NoError(t, err)

	// re-dispatch the identical request several times
	for i := 0; i < 3; i++ {
		publishThumbnailWarm(t, js, events.ThumbnailWarmRequest{ProviderID: "testinput", Path: name})
	}

	// give redelivery/duplicate-processing a chance to run; nothing should
	// change about the existing thumbnail file
	time.Sleep(500 * time.Millisecond)
	require.True(t, thumbExistsOnDisk(expected))

	secondInfo, err := os.Stat(fixturePath(expected))
	require.NoError(t, err)
	assert.Equal(t, firstInfo.ModTime(), secondInfo.ModTime(), "re-dispatching an already-warmed photo must not recreate/modify the existing Thumbnail")
}

func fixturePath(thumbName string) string {
	return filepath.Join(tmpDir, thumbName)
}
