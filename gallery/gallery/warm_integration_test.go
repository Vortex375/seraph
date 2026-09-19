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

package gallery_test

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/gallery/gallery"
)

// warmWatcher subscribes as a plain core-NATS subscriber to
// events.ThumbnailWarmTopic and records every ThumbnailWarmRequest
// observed on it. A JetStream publish is still an ordinary NATS publish on
// the wire, so a plain subscription sees it exactly like a durable
// JetStream consumer would, without this test needing its own consumer -
// this is the "asserted as a publish onto the queue" boundary ticket 11
// calls for dispatch coverage.
type warmWatcher struct {
	mu       sync.Mutex
	requests []events.ThumbnailWarmRequest
}

func watchThumbnailWarm(t *testing.T, nc *nats.Conn) *warmWatcher {
	t.Helper()

	w := &warmWatcher{}
	sub, err := nc.Subscribe(events.ThumbnailWarmTopic, func(msg *nats.Msg) {
		req := events.ThumbnailWarmRequest{}
		if err := json.Unmarshal(msg.Data, &req); err != nil {
			return
		}
		w.mu.Lock()
		w.requests = append(w.requests, req)
		w.mu.Unlock()
	})
	require.NoError(t, err)
	t.Cleanup(func() { sub.Unsubscribe() })
	require.NoError(t, nc.Flush())

	return w
}

func (w *warmWatcher) snapshot() []events.ThumbnailWarmRequest {
	w.mu.Lock()
	defer w.mu.Unlock()
	out := make([]events.ThumbnailWarmRequest, len(w.requests))
	copy(out, w.requests)
	return out
}

func (w *warmWatcher) count() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return len(w.requests)
}

// waitForWarmCount polls until the watcher has observed at least n
// ThumbnailWarmRequests, or fails the test - dispatch happens on the same
// asynchronous ingest/backfill paths every other gallery test already polls
// for.
func waitForWarmCount(t *testing.T, w *warmWatcher, n int) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if w.count() >= n {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("expected at least %d ThumbnailWarmRequest publishes, got %d after deadline", n, w.count())
}

// TestWarmOnIngestDispatchesRequestOntoDurableQueue covers: a photo
// entering the read model via live ingestion results in a
// ThumbnailWarmRequest published onto the durable warm queue - dispatch
// asserted at the NATS boundary as a publish, not by inspecting internal
// state.
func TestWarmOnIngestDispatchesRequestOntoDurableQueue(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	watcher := watchThumbnailWarm(t, nc)

	dir := startFileProvider(t, "physical-photos")

	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})

	data := buildJPEGWithExif(t, 40, 30, "2019:06:15 10:20:30", 1)
	physicalPath := "/mounted/photos/holidays/beach.jpg"
	writeFixture(t, dir, physicalPath, data)

	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")

	waitForPhoto(t, db, "physical-photos", physicalPath)
	waitForWarmCount(t, watcher, 1)

	found := false
	for _, req := range watcher.snapshot() {
		if req.ProviderID == "physical-photos" && req.Path == physicalPath {
			found = true
		}
	}
	assert.True(t, found, "expected a ThumbnailWarmRequest for the physical (providerId, path) that just entered the read model")
}

// TestWarmIsNotDispatchedForAlreadyUnsupportedPhoto covers a corollary of
// warm-on-ingest: a file already known undecodable at ingest time (recorded
// with an UnsupportedReason*) is not pointlessly dispatched to the
// thumbnailer, which could only fail identically.
func TestWarmIsNotDispatchedForAlreadyUnsupportedPhoto(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	watcher := watchThumbnailWarm(t, nc)

	dir := startFileProvider(t, "physical-photos")

	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})

	data := []byte("this is not an image, just plain bytes pretending to be a RAW file")
	physicalPath := "/mounted/photos/holidays/raw.arw"
	writeFixture(t, dir, physicalPath, data)

	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "application/octet-stream")

	photo := waitForPhoto(t, db, "physical-photos", physicalPath)
	require.Equal(t, gallery.UnsupportedReasonFormat, photo.Unsupported)

	// give dispatch a chance to have happened if it were (incorrectly) going to
	time.Sleep(300 * time.Millisecond)
	for _, req := range watcher.snapshot() {
		assert.NotEqual(t, physicalPath, req.Path, "an already-unsupported photo must not be dispatched for warming")
	}
}

// TestWarmOnBackfillDispatchesEveryPhotoWithNoSilentLosses covers: backfilling
// a folder of many photos dispatches a ThumbnailWarmRequest for every one of
// them - none silently missing - which is the entire reason this ticket
// requires a durable queue rather than firing interactive requests at the
// thumbnailer.
func TestWarmOnBackfillDispatchesEveryPhotoWithNoSilentLosses(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	watcher := watchThumbnailWarm(t, nc)

	const count = 250
	stub := newStubFileIndex(t, nc, 37) // page size deliberately unaligned to count
	entries := make([]events.FileIndexListEntry, 0, count)
	for i := 0; i < count; i++ {
		entries = append(entries, fileEntry(fmt.Sprintf("/holidays/photo_%04d.jpg", i), 1024, time.Now().Unix(), "image/jpeg"))
	}
	stub.set("physical-photos", "/mounted/photos/holidays", withProvider("physical-photos", entries))

	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})

	waitForPhotoCount(t, db, "physical-photos", count)
	waitForWarmCount(t, watcher, count)

	seen := make(map[string]bool, count)
	for _, req := range watcher.snapshot() {
		if req.ProviderID == "physical-photos" {
			seen[req.Path] = true
		}
	}
	missing := 0
	for _, e := range entries {
		if !seen[e.Path] {
			missing++
		}
	}
	assert.Equal(t, 0, missing, "every backfilled photo must get a ThumbnailWarmRequest dispatched - no silent losses")
}

// TestWarmIsNotRedispatchedForAlreadyIngestedPhotoDuringBackfill covers
// re-dispatch harmlessness from the gallery side of the seam: TWO
// independent Gallery Source Folders whose physical prefixes overlap (a
// nested folder, exactly like TestNestedFolderDoesNotDoubleBackfilledPhotos
// covers for the read model itself) both backfill the SAME physical file.
// The second folder's backfillUpsert is a $setOnInsert-only no-op for that
// key (see backfillUpsert's docs) and must not dispatch a second warm
// request for it - only the first, genuinely-inserting backfill dispatches.
//
// This is deliberately NOT a live-event-vs-backfill race: upsertPhoto (the
// live path) dispatches on every call, insert or update, by design - a live
// "changed" event always warrants a fresh warm - so a live event racing
// backfill for the same key can legitimately produce two dispatches. That
// is fine: re-dispatch is required to be HARMLESS (see
// TestRedispatchingSamePhotoIsHarmless in the thumbnailer package), not
// eliminated. What backfillUpsert's own no-op path must avoid is dispatching
// AGAIN for a key it did not itself just insert.
func TestWarmIsNotRedispatchedForAlreadyIngestedPhotoDuringBackfill(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	watcher := watchThumbnailWarm(t, nc)

	physicalPath := "/mounted/photos/holidays/2024/shared.jpg"
	entry := fileEntry(physicalPath, 1024, time.Now().Unix(), "image/jpeg")

	stub := newStubFileIndex(t, nc, 10)
	// the outer folder's backfill walks the file under its own prefix...
	stub.set("physical-photos", "/mounted/photos/holidays", withProvider("physical-photos", []events.FileIndexListEntry{entry}))
	// ...and the nested folder's independent backfill walks the SAME
	// physical file again, under its own (narrower) prefix
	stub.set("physical-photos", "/mounted/photos/holidays/2024", withProvider("physical-photos", []events.FileIndexListEntry{entry}))

	outer := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	require.Equal(t, "", outer.Error)
	waitForPhoto(t, db, "physical-photos", physicalPath)
	waitForWarmCount(t, watcher, 1)

	nested := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays/2024",
	})
	require.Equal(t, "", nested.Error)

	// give the nested folder's backfill (a guaranteed no-op for this key)
	// time to run
	time.Sleep(500 * time.Millisecond)

	count := 0
	for _, req := range watcher.snapshot() {
		if req.Path == physicalPath {
			count++
		}
	}
	assert.Equal(t, 1, count, "a second folder's backfill no-op for an already-ingested photo must not dispatch a second warm request")
}

// TestUnsupportedNoticeFromThumbnailerRecordsReasonAgainstPhoto covers: the
// gallery service, on the receiving end of the "recording the reason means
// a message back to the gallery service" seam, records a
// ThumbnailWarmUnsupportedNotice's Reason against the corresponding
// galleryPhotos document's Unsupported field.
func TestUnsupportedNoticeFromThumbnailerRecordsReasonAgainstPhoto(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	dir := startFileProvider(t, "physical-photos")

	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})

	// ingest a normal, decodable photo first - Unsupported starts empty
	data := buildJPEGWithExif(t, 12, 8, "2021:01:01 12:00:00", 1)
	physicalPath := "/mounted/photos/holidays/later-flagged.jpg"
	writeFixture(t, dir, physicalPath, data)
	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")
	photo := waitForPhoto(t, db, "physical-photos", physicalPath)
	require.Equal(t, "", photo.Unsupported)

	// simulate the thumbnailer reporting back that it could not decode this
	// photo for warming - published exactly like the real thumbnailer's
	// warm consumer does (fire-and-forget onto the durable queue)
	publishWarmUnsupported(t, nc, events.ThumbnailWarmUnsupportedNotice{
		ProviderID: "physical-photos",
		Path:       physicalPath,
		Reason:     gallery.UnsupportedReasonCorrupt,
	})

	waitForCondition(t, func() bool {
		p := findPhoto(t, db, "physical-photos", physicalPath)
		return p != nil && p.Unsupported == gallery.UnsupportedReasonCorrupt
	}, "expected the reported reason to be recorded against the gallery item")
}

// TestUnsupportedNoticeForUnknownPhotoIsHarmless covers the edge where the
// photo no longer exists in the read model by the time the thumbnailer
// reports back (e.g. deleted meanwhile) - this must not error the consumer
// or panic; there is simply nothing to record the reason against.
func TestUnsupportedNoticeForUnknownPhotoIsHarmless(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	publishWarmUnsupported(t, nc, events.ThumbnailWarmUnsupportedNotice{
		ProviderID: "physical-photos",
		Path:       "/holidays/never-existed.jpg",
		Reason:     gallery.UnsupportedReasonFormat,
	})

	// nothing to assert on the database beyond "no photo appears" - the
	// meaningful assertion is that the consumer keeps running afterwards,
	// proven by publishing a second, valid notice and observing it recorded
	dir := startFileProvider(t, "physical-photos")
	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	data := buildJPEGWithExif(t, 12, 8, "2021:01:01 12:00:00", 1)
	physicalPath := "/mounted/photos/holidays/still-works.jpg"
	writeFixture(t, dir, physicalPath, data)
	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")
	waitForPhoto(t, db, "physical-photos", physicalPath)

	publishWarmUnsupported(t, nc, events.ThumbnailWarmUnsupportedNotice{
		ProviderID: "physical-photos",
		Path:       physicalPath,
		Reason:     gallery.UnsupportedReasonFormat,
	})

	waitForCondition(t, func() bool {
		p := findPhoto(t, db, "physical-photos", physicalPath)
		return p != nil && p.Unsupported == gallery.UnsupportedReasonFormat
	}, "the consumer must keep processing notices after one for an unknown photo")
}

// TestUnsupportedNoticeReachesAMirrorThatAlreadyPolledPastThePhoto covers the
// delta-feed half of recording the reason: a mirror that has ALREADY polled
// past a photo's sequence must still learn that the photo later became
// unsupported. Without recordUnsupported bumping Seq, that mirror would keep
// showing it as an ordinary photo forever - the exact failure ticket 10's
// feed exists to prevent.
//
// It also covers the redelivery half: a duplicate notice for an
// already-recorded value must NOT produce a second delta delivery, since
// that would churn the feed and re-deliver an unchanged document to every
// mirror for nothing.
func TestUnsupportedNoticeReachesAMirrorThatAlreadyPolledPastThePhoto(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)
	clearPendingTombstones(t, db)

	dir := startFileProvider(t, "physical-photos")

	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})

	physicalPath := "/mounted/photos/holidays/flagged-later.jpg"
	spacePath := "/holidays/flagged-later.jpg"
	photo := createPhoto(t, nc, db, dir, "physical-photos", physicalPath)
	require.Equal(t, "", photo.Unsupported)

	// the mirror completes a full poll: it has now seen this photo and its
	// cursor sits past that photo's sequence
	items, since := deltaAll(t, nc, "pino", 0)
	seen := false
	for _, it := range items {
		if it.Path == spacePath {
			seen = true
			assert.Equal(t, "", it.Unsupported)
		}
	}
	require.True(t, seen, "sanity: the photo must be in the mirror's first poll")

	// the thumbnailer now reports it cannot decode this photo for warming
	publishWarmUnsupported(t, nc, events.ThumbnailWarmUnsupportedNotice{
		ProviderID: "physical-photos",
		Path:       physicalPath,
		Reason:     gallery.UnsupportedReasonCorrupt,
	})
	waitForCondition(t, func() bool {
		p := findPhoto(t, db, "physical-photos", physicalPath)
		return p != nil && p.Unsupported == gallery.UnsupportedReasonCorrupt
	}, "expected the reported reason to be recorded against the gallery item")

	// polling from where the mirror left off must now deliver the photo
	// again, carrying the newly recorded reason
	items, since = deltaAll(t, nc, "pino", since)
	redelivered := 0
	for _, it := range items {
		if it.Path == spacePath {
			redelivered++
			assert.Equal(t, gallery.UnsupportedReasonCorrupt, it.Unsupported)
		}
	}
	assert.Equal(t, 1, redelivered, "a photo flagged unsupported after the mirror polled past it must arrive on the next poll")

	// a DUPLICATE notice for the same, already-recorded value must not bump
	// the sequence again - the next poll must be empty for this photo
	publishWarmUnsupported(t, nc, events.ThumbnailWarmUnsupportedNotice{
		ProviderID: "physical-photos",
		Path:       physicalPath,
		Reason:     gallery.UnsupportedReasonCorrupt,
	})

	// give the duplicate time to be consumed and (incorrectly) re-bump
	time.Sleep(500 * time.Millisecond)

	items, _ = deltaAll(t, nc, "pino", since)
	for _, it := range items {
		assert.NotEqual(t, spacePath, it.Path, "a duplicate unsupported notice must not re-deliver the document to mirrors")
	}
}

// publishWarmUnsupported publishes a ThumbnailWarmUnsupportedNotice onto the
// durable warm-unsupported queue, creating the stream first if needed -
// mirroring how the real thumbnailer's warm consumer does it.
func publishWarmUnsupported(t *testing.T, nc *nats.Conn, notice events.ThumbnailWarmUnsupportedNotice) {
	t.Helper()

	js, err := jetstream.New(nc)
	require.NoError(t, err)

	_, err = js.CreateOrUpdateStream(context.Background(), jetstream.StreamConfig{
		Name:      events.ThumbnailWarmUnsupportedStream,
		Subjects:  []string{events.ThumbnailWarmUnsupportedTopic},
		Retention: jetstream.WorkQueuePolicy,
	})
	require.NoError(t, err)

	data, err := json.Marshal(notice)
	require.NoError(t, err)

	_, err = js.Publish(context.Background(), events.ThumbnailWarmUnsupportedTopic, data)
	require.NoError(t, err)
}
