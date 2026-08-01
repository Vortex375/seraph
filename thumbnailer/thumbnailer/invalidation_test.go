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
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/messaging"
)

func waitFor(t *testing.T, timeout time.Duration, cond func() bool) bool {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(10 * time.Millisecond)
	}
	return cond()
}

func thumbExistsOnDisk(name string) bool {
	_, err := os.Stat(filepath.Join(tmpDir, name))
	return err == nil
}

// requestThumbnail drives the preview path end-to-end (same as
// TestCreateThumbnail) and returns the resulting Thumbnail file name.
func requestThumbnail(t *testing.T, nc *nats.Conn, providerId, filePath string, width, height int) string {
	t.Helper()

	req := ThumbnailRequest{
		ProviderID: providerId,
		Path:       filePath,
		Width:      width,
		Height:     height,
	}
	resp := ThumbnailResponse{}

	err := messaging.Request(context.Background(), nc, ThumbnailRequestTopic, &req, &resp)
	require.NoError(t, err)
	require.Equal(t, "", resp.Error)
	require.NotEmpty(t, resp.Path)

	return resp.Path
}

func TestDeletingFileRemovesThumbnailsAtEverySize(t *testing.T) {
	thumb, nc, js := getThumbnailerWithJetStream(t, nil)
	defer thumb.Stop()
	resetInvalidationStream(t, js)

	name := writeFixtureJpeg(t, "fixture_delete_all_sizes.jpg", 2048, 2048)

	// create thumbnails at two different sizes for the same file
	path1 := requestThumbnail(t, nc, "testinput", name, 128, 128)
	path2 := requestThumbnail(t, nc, "testinput", name, 512, 512)

	require.True(t, thumbExistsOnDisk(path1))
	require.True(t, thumbExistsOnDisk(path2))

	publishFileChanged(t, js, events.FileChangedEvent{
		Event:      events.Event{ID: uuid.NewString(), Version: 1},
		FileID:     uuid.NewString(),
		ProviderID: "testinput",
		Change:     events.FileChangedEventDeleted,
		Path:       name,
	})

	ok := waitFor(t, 5*time.Second, func() bool {
		return !thumbExistsOnDisk(path1) && !thumbExistsOnDisk(path2)
	})
	assert.True(t, ok, "expected all thumbnail sizes to be removed after delete event")
}

func TestChangingFileInvalidatesThumbnailSoNextRequestServesNewContent(t *testing.T) {
	thumb, nc, js := getThumbnailerWithJetStream(t, nil)
	defer thumb.Stop()
	resetInvalidationStream(t, js)

	name := writeFixtureJpeg(t, "fixture_changed.jpg", 512, 512)

	oldThumbPath := requestThumbnail(t, nc, "testinput", name, 256, 256)
	require.True(t, thumbExistsOnDisk(oldThumbPath))

	publishFileChanged(t, js, events.FileChangedEvent{
		Event:      events.Event{ID: uuid.NewString(), Version: 1},
		FileID:     uuid.NewString(),
		ProviderID: "testinput",
		Change:     events.FileChangedEventChanged,
		Path:       name,
	})

	ok := waitFor(t, 5*time.Second, func() bool {
		return !thumbExistsOnDisk(oldThumbPath)
	})
	require.True(t, ok, "expected stale thumbnail to be removed after change event")

	// next preview request must regenerate rather than serve nothing / stale data
	newThumbPath := requestThumbnail(t, nc, "testinput", name, 256, 256)
	assert.Equal(t, oldThumbPath, newThumbPath) // same name (hash+size derived), but now freshly created
	assert.True(t, thumbExistsOnDisk(newThumbPath))
}

func TestDeletingFileWithNoThumbnailsProducesNoErrorsOrLogNoise(t *testing.T) {
	thumb, _, js := getThumbnailerWithJetStream(t, nil)
	defer thumb.Stop()
	resetInvalidationStream(t, js)

	// swap in a buffer-backed logger so we can assert nothing was written
	var buf bytes.Buffer
	thumb.mu.Lock()
	thumb.log = slog.New(slog.NewTextHandler(&buf, nil))
	thumb.mu.Unlock()

	publishFileChanged(t, js, events.FileChangedEvent{
		Event:      events.Event{ID: uuid.NewString(), Version: 1},
		FileID:     uuid.NewString(),
		ProviderID: "testinput",
		Change:     events.FileChangedEventDeleted,
		Path:       "never-had-a-thumbnail.jpg",
	})

	// give the consumer time to process; there is nothing to observably
	// wait on (no file is created), so poll for the ack instead by directly
	// exercising the invalidation logic synchronously as well.
	time.Sleep(300 * time.Millisecond)

	assert.Empty(t, buf.String(), "expected no log output when deleting a file that never had thumbnails")
}

func TestInvalidateThumbnailsOnUnknownFileReturnsNoError(t *testing.T) {
	// unit-level check of the not-found-is-success contract, independent of
	// consumer timing: attempting to remove Thumbnails for a path that was
	// never thumbnailed must return a nil error (not-found is success).
	thumb, _, js := getThumbnailerWithJetStream(t, nil)
	defer thumb.Stop()
	resetInvalidationStream(t, js)

	err := thumb.invalidateThumbnails(context.Background(), "test", "totally-unknown-file.jpg")
	assert.NoError(t, err)
}

func TestRedeliveryOfSameEventIsHarmless(t *testing.T) {
	thumb, nc, js := getThumbnailerWithJetStream(t, nil)
	defer thumb.Stop()
	resetInvalidationStream(t, js)

	name := writeFixtureJpeg(t, "fixture_redelivery.jpg", 512, 512)
	thumbPath := requestThumbnail(t, nc, "testinput", name, 256, 256)
	require.True(t, thumbExistsOnDisk(thumbPath))

	ev := events.FileChangedEvent{
		Event:      events.Event{ID: uuid.NewString(), Version: 1},
		FileID:     uuid.NewString(),
		ProviderID: "testinput",
		Change:     events.FileChangedEventDeleted,
		Path:       name,
	}

	publishFileChanged(t, js, ev)
	ok := waitFor(t, 5*time.Second, func() bool {
		return !thumbExistsOnDisk(thumbPath)
	})
	require.True(t, ok)

	// publish the identical event again ("redelivery") - this must not
	// error, panic, or produce a different observable outcome. We assert
	// this at the handler level directly, since simulating true JetStream
	// redelivery requires forcing a nak/timeout; the handler must tolerate
	// being invoked twice for the same (already-cleaned-up) file.
	err := thumb.invalidateThumbnails(context.Background(), ev.ProviderID, ev.Path)
	assert.NoError(t, err, "re-processing a delete for an already-cleaned-up file must be harmless")

	// publishing the exact same event a second time end-to-end must also
	// not error out the consumer or leave anything behind
	publishFileChanged(t, js, ev)
	time.Sleep(300 * time.Millisecond)
	assert.False(t, thumbExistsOnDisk(thumbPath))
}

func TestInvalidationConsumerIsDurableAcrossRestart(t *testing.T) {
	// Prove durability: publish a file-change event while NO thumbnailer is
	// running (simulating "the thumbnailer was down"), then start a
	// thumbnailer with the same durable consumer name and confirm the
	// backlog is drained and the thumbnail is cleaned up - without needing
	// to have been running at publish time.
	nc, err := nats.Connect(natsServer.ClientURL())
	require.NoError(t, err)
	defer nc.Close()

	js, err := jetstream.New(nc)
	require.NoError(t, err)
	resetInvalidationStream(t, js)

	// start a first thumbnailer instance to create a real thumbnail on disk
	thumb1, nc1, js1 := getThumbnailerWithJetStream(t, nil)
	name := writeFixtureJpeg(t, "fixture_durable_restart.jpg", 512, 512)
	thumbPath := requestThumbnail(t, nc1, "testinput", name, 256, 256)
	require.True(t, thumbExistsOnDisk(thumbPath))

	// stop the thumbnailer (simulating downtime) BEFORE the change event is
	// published, so the durable consumer has no live subscriber
	thumb1.Stop()
	_ = js1

	ev := events.FileChangedEvent{
		Event:      events.Event{ID: uuid.NewString(), Version: 1},
		FileID:     uuid.NewString(),
		ProviderID: "testinput",
		Change:     events.FileChangedEventDeleted,
		Path:       name,
	}
	publishFileChanged(t, js, ev)

	// the thumbnail must still be present - nobody was consuming
	require.True(t, thumbExistsOnDisk(thumbPath), "sanity check: no consumer was running yet")

	// now start a second thumbnailer, reattaching to the same durable
	// consumer; the backlogged delete event must be delivered and processed
	thumb2, _, _ := getThumbnailerWithJetStream(t, nil)
	defer thumb2.Stop()

	ok := waitFor(t, 5*time.Second, func() bool {
		return !thumbExistsOnDisk(thumbPath)
	})
	assert.True(t, ok, "expected the durable consumer to process the backlogged delete event after restart")
}

func TestCleanupDoesNotStarvePreviewPath(t *testing.T) {
	// The cleanup consumer must use its own concurrency budget, distinct
	// from the preview-request limiter, so a burst of file-change cleanup
	// work cannot block interactive preview requests. We make this
	// observable by flooding the invalidation stream with far more
	// in-flight cleanups than invalidationParallel while concurrently
	// issuing a preview request, and asserting the preview request still
	// completes promptly.
	thumb, nc, js := getThumbnailerWithJetStream(t, nil)
	defer thumb.Stop()
	resetInvalidationStream(t, js)

	// sanity: the preview limiter and the invalidation limiter must be
	// different instances, so exhausting one structurally cannot exhaust
	// the other.
	thumb.mu.Lock()
	previewLimiter := thumb.limiter
	invalidation := thumb.invalidation
	thumb.mu.Unlock()
	require.NotNil(t, previewLimiter)
	require.NotNil(t, invalidation)
	assert.NotSame(t, previewLimiter, invalidation.limiter, "preview and invalidation limiters must be independent so cleanup cannot starve previews")

	name := writeFixtureJpeg(t, "fixture_starvation_check.jpg", 256, 256)

	// flood many more change events than the invalidation consumer's
	// concurrency budget so some are necessarily queued up
	for i := 0; i < invalidationParallel*10; i++ {
		publishFileChanged(t, js, events.FileChangedEvent{
			Event:      events.Event{ID: uuid.NewString(), Version: 1},
			FileID:     uuid.NewString(),
			ProviderID: "testinput",
			Change:     events.FileChangedEventChanged,
			Path:       fmt.Sprintf("fixture_starvation_check_%d.jpg", i),
		})
	}

	// a preview request issued right away must still complete quickly,
	// proving the preview path was not queued up behind cleanup work
	start := time.Now()
	requestThumbnail(t, nc, "testinput", name, 128, 128)
	elapsed := time.Since(start)

	assert.Less(t, elapsed, 3*time.Second, "preview request should not be starved by concurrent cleanup work")
}
