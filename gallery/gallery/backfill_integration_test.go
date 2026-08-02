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

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/gallery/gallery"
)

// stubFileIndex answers events.FileIndexListRequest with entries it was
// preloaded with, following the same ack-then-one-reply-per-page protocol
// the real file-indexer implements (see file-indexer/fileindexer/list.go).
// Tests preload entries (see set) and can observe every request it received
// (see requests) to assert paging/cursor behaviour without a real MongoDB
// -backed file index.
type stubFileIndex struct {
	t           *testing.T
	nc          *nats.Conn
	sub         *nats.Subscription
	pageSize    int
	mu          sync.Mutex
	entries     map[string][]events.FileIndexListEntry // providerId+"\x00"+path -> entries, in return order
	requests    []events.FileIndexListRequest
	beforeReply func(req events.FileIndexListRequest) // test hook, called synchronously before replying
}

// newStubFileIndex starts a stub File Index responder on nc. pageSize bounds
// how many entries are returned per reply, letting tests force multi-page
// backfills with small fixture sets.
func newStubFileIndex(t *testing.T, nc *nats.Conn, pageSize int) *stubFileIndex {
	t.Helper()
	s := &stubFileIndex{
		t:        t,
		nc:       nc,
		pageSize: pageSize,
		entries:  make(map[string][]events.FileIndexListEntry),
	}

	sub, err := nc.Subscribe(events.FileIndexListRequestTopic, func(msg *nats.Msg) {
		req := events.FileIndexListRequest{}
		if err := json.Unmarshal(msg.Data, &req); err != nil {
			return
		}

		s.mu.Lock()
		s.requests = append(s.requests, req)
		s.mu.Unlock()

		ack := events.FileIndexListAck{RequestId: req.RequestId, ReplyId: uuid.NewString(), Ack: true}
		ackData, _ := json.Marshal(ack)
		nc.Publish(fmt.Sprintf(events.FileIndexListAckTopicPattern, req.RequestId), ackData)

		if s.beforeReply != nil {
			s.beforeReply(req)
		}

		reply := s.page(req)
		replyData, _ := json.Marshal(reply)
		nc.Publish(fmt.Sprintf(events.FileIndexListReplyTopicPattern, req.RequestId), replyData)
	})
	require.NoError(t, err)
	t.Cleanup(func() { sub.Unsubscribe() })
	s.sub = sub

	require.NoError(t, nc.Flush())

	return s
}

// key identifies one (providerId, prefix path) the stub was given entries
// for; the cursor is an index into that entry list.
func key(providerId, prefixPath string) string {
	return providerId + "\x00" + prefixPath
}

// set preloads the entries the stub returns for a (providerId, prefixPath)
// request, in the order they will be paged out.
func (s *stubFileIndex) set(providerId, prefixPath string, entries []events.FileIndexListEntry) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.entries[key(providerId, prefixPath)] = entries
}

// page implements one FileIndexListRequest -> FileIndexListReply turn: the
// cursor is simply the decimal offset into the preloaded slice, which is
// all a stub needs - it does not have to reimplement the real path-keyset
// cursor scheme ticket 04 built, only honour the same "cursor in, cursor
// out, HasMore" contract backfill depends on.
func (s *stubFileIndex) page(req events.FileIndexListRequest) events.FileIndexListReply {
	s.mu.Lock()
	defer s.mu.Unlock()

	all := s.entries[key(req.ProviderId, req.Path)]

	offset := 0
	if req.Cursor != "" {
		fmt.Sscanf(req.Cursor, "%d", &offset)
	}

	pageSize := s.pageSize
	if pageSize <= 0 {
		pageSize = len(all)
		if pageSize == 0 {
			pageSize = 1
		}
	}

	end := offset + pageSize
	hasMore := end < len(all)
	if end > len(all) {
		end = len(all)
	}

	var entries []events.FileIndexListEntry
	if offset < len(all) {
		entries = all[offset:end]
	}

	nextCursor := ""
	if hasMore {
		nextCursor = fmt.Sprintf("%d", end)
	}

	return events.FileIndexListReply{
		RequestId:  req.RequestId,
		Entries:    entries,
		NextCursor: nextCursor,
		HasMore:    hasMore,
		Last:       true,
	}
}

// requestCount returns how many FileIndexListRequests the stub has answered
// so far, for asserting paging happened (or resumed) as expected.
func (s *stubFileIndex) requestCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.requests)
}

// waitForPhotoCount polls until exactly n non-deleted-agnostic galleryPhotos
// documents exist for providerId, or fails the test - backfill runs on a
// background goroutine, so tests need to wait for it to land rather than
// asserting immediately after ADD.
func waitForPhotoCount(t *testing.T, db *mongo.Database, providerId string, n int) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	var last int64 = -1
	for time.Now().Before(deadline) {
		count, err := db.Collection("galleryPhotos").CountDocuments(context.Background(), bson.M{"providerId": providerId})
		require.NoError(t, err)
		last = count
		if count == int64(n) {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("expected %d gallery photos for provider %s, got %d after deadline", n, providerId, last)
}

func fileEntry(path string, size int64, modTime int64, mime string) events.FileIndexListEntry {
	return events.FileIndexListEntry{
		ProviderId: "", // filled by caller via stub key, not carried per-entry in these tests
		Path:       path,
		Size:       size,
		ModTime:    modTime,
		Mime:       mime,
	}
}

// withProvider stamps ProviderId onto a batch of entries built via
// fileEntry, since FileIndexListEntry carries it per-entry in the real
// protocol even though these fixtures build it once per test.
func withProvider(providerId string, entries []events.FileIndexListEntry) []events.FileIndexListEntry {
	out := make([]events.FileIndexListEntry, len(entries))
	for i, e := range entries {
		e.ProviderId = providerId
		out[i] = e
	}
	return out
}

// TestAddFolderBackfillsAlreadyIndexedPhotos covers the ticket's core
// requirement: adding a folder containing photos the File Index already
// knows about makes them appear in the gallery listing, without any live
// file-change event ever being published for them.
func TestAddFolderBackfillsAlreadyIndexedPhotos(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	stub := newStubFileIndex(t, nc, 0)
	stub.set("physical-photos", "/mounted/photos/holidays", withProvider("physical-photos", []events.FileIndexListEntry{
		fileEntry("/mounted/photos/holidays/a.jpg", 100, time.Date(2015, 6, 1, 0, 0, 0, 0, time.UTC).Unix(), "image/jpeg"),
		fileEntry("/mounted/photos/holidays/b.jpg", 200, time.Date(2016, 7, 1, 0, 0, 0, 0, time.UTC).Unix(), "image/jpeg"),
	}))

	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	require.Equal(t, "", res.Error)

	waitForPhotoCount(t, db, "physical-photos", 2)

	a := findPhoto(t, db, "physical-photos", "/mounted/photos/holidays/a.jpg")
	require.NotNil(t, a)
	assert.True(t, a.MetadataPending, "a backfilled photo must be flagged MetadataPending until a live event heals it")
	assert.Equal(t, gallery.CaptureDateSourceModTime, a.CapturedAtSource)
	assert.Equal(t, time.Date(2015, 6, 1, 0, 0, 0, 0, time.UTC).Unix(), a.CapturedAt)

	// and it is visible through the listing API, not just the raw read model
	listRes := list(t, nc, &gallery.GalleryListRequest{UserId: "pino"})
	require.Equal(t, "", listRes.Error)
	assert.Len(t, listRes.Items, 2)
	for _, item := range listRes.Items {
		assert.True(t, item.MetadataPending)
	}
}

// TestAddReturnsPromptlyWhileBackfillRunsInBackground covers: the ADD
// request/reply completes without waiting for backfill, even when backfill
// has many pages to walk. A slow/blocking stub responder (via beforeReply)
// would stall ADD if backfill were on the request path; it must not.
func TestAddReturnsPromptlyWhileBackfillRunsInBackground(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	stub := newStubFileIndex(t, nc, 1)
	entries := withProvider("physical-photos", []events.FileIndexListEntry{
		fileEntry("/mounted/photos/holidays/a.jpg", 1, 1000, "image/jpeg"),
		fileEntry("/mounted/photos/holidays/b.jpg", 1, 1000, "image/jpeg"),
		fileEntry("/mounted/photos/holidays/c.jpg", 1, 1000, "image/jpeg"),
	})
	stub.set("physical-photos", "/mounted/photos/holidays", entries)

	// each page reply is artificially delayed so that, if ADD accidentally
	// blocked on backfill, this test would time out long before the 10s
	// budget below elapses
	stub.beforeReply = func(req events.FileIndexListRequest) {
		time.Sleep(300 * time.Millisecond)
	}

	start := time.Now()
	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	elapsed := time.Since(start)

	require.Equal(t, "", res.Error)
	assert.Less(t, elapsed, 250*time.Millisecond, "ADD must return before even a single (deliberately slow) backfill page completes")

	// backfill still eventually completes in the background
	waitForPhotoCount(t, db, "physical-photos", 3)
}

// TestBackfillInterleavedWithLiveEventsProducesOneItem is the ticket's
// explicitly-demanded test: backfill and a live file-change event racing for
// the same physical file must produce exactly one gallery item, not two -
// and the live event's fuller extraction must win regardless of arrival
// order, since it is strictly more informative than a backfill placeholder.
func TestBackfillInterleavedWithLiveEventsProducesOneItem(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	dir := startFileProvider(t, "physical-photos")

	stub := newStubFileIndex(t, nc, 1)
	physicalPath := "/mounted/photos/holidays/race.jpg"
	entries := withProvider("physical-photos", []events.FileIndexListEntry{
		fileEntry(physicalPath, 1, time.Date(2010, 1, 1, 0, 0, 0, 0, time.UTC).Unix(), "image/jpeg"),
		fileEntry("/mounted/photos/holidays/other.jpg", 1, 1000, "image/jpeg"),
	})
	stub.set("physical-photos", "/mounted/photos/holidays", entries)

	// fire the live event for the raced file the moment the FIRST backfill
	// page request comes in, so the live event and backfill's own upsert for
	// the same key are genuinely interleaved rather than sequential
	var once sync.Once
	data := buildJPEGWithExif(t, 12, 8, "2021:03:03 03:03:03", 0)
	writeFixture(t, dir, physicalPath, data)
	stub.beforeReply = func(req events.FileIndexListRequest) {
		once.Do(func() {
			publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")
		})
	}

	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	require.Equal(t, "", res.Error)

	waitForPhotoCount(t, db, "physical-photos", 2)

	// exactly one document for the raced path, not two
	count, err := db.Collection("galleryPhotos").CountDocuments(context.Background(), bson.M{
		"providerId": "physical-photos",
		"path":       physicalPath,
	})
	require.NoError(t, err)
	assert.Equal(t, int64(1), count)

	// whichever order the live event and backfill's upsert actually landed
	// in, the live event's full extraction must be what is visible in the
	// end - a live event is strictly more informative and always wins (see
	// upsertPhoto's docs)
	waitForCondition(t, func() bool {
		p := findPhoto(t, db, "physical-photos", physicalPath)
		return p != nil && !p.MetadataPending
	}, "the live event's extraction never won out over the backfill placeholder")

	final := findPhoto(t, db, "physical-photos", physicalPath)
	require.NotNil(t, final)
	assert.Equal(t, gallery.CaptureDateSourceExif, final.CapturedAtSource)
	assert.Equal(t, 12, final.Width)
	assert.False(t, final.MetadataPending)
}

// TestBackfillRestartDoesNotDuplicate covers: a backfill interrupted before
// completion (simulated here by stopping the provider mid-backfill, as a
// restart would) resumes cleanly on the next Start() and produces exactly
// one document per file, never two.
func TestBackfillRestartDoesNotDuplicate(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	stub := newStubFileIndex(t, nc, 1)
	entries := withProvider("physical-photos", []events.FileIndexListEntry{
		fileEntry("/mounted/photos/holidays/a.jpg", 1, 1000, "image/jpeg"),
		fileEntry("/mounted/photos/holidays/b.jpg", 1, 1000, "image/jpeg"),
		fileEntry("/mounted/photos/holidays/c.jpg", 1, 1000, "image/jpeg"),
	})
	stub.set("physical-photos", "/mounted/photos/holidays", entries)

	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	require.Equal(t, "", res.Error)
	folderId := res.SourceFolder[0].Id

	// let at least one page land, then simulate a restart before backfill
	// finishes by marking progress incomplete again and re-running the
	// resume path directly - this exercises exactly the code path Start()
	// calls at startup (resumeIncompleteBackfills), which is what a real
	// process restart would trigger.
	waitForCondition(t, func() bool {
		count, err := db.Collection("galleryPhotos").CountDocuments(context.Background(), bson.M{"providerId": "physical-photos"})
		require.NoError(t, err)
		return count >= 1
	}, "expected at least one page of backfill to have landed before simulating a restart")

	// Force backfillDone back to false with the cursor rolled back to the
	// start, as if the process had died before completing but after writing
	// some progress - the worst case for duplication, since it guarantees
	// re-processing of already-upserted entries.
	_, err := db.Collection("gallerySourceFolders").UpdateByID(context.Background(), folderId, bson.M{
		"$set": bson.M{"backfillDone": false, "backfillCursor": ""},
	})
	require.NoError(t, err)

	provider, resumeNc, resumeDb := getGalleryProvider(t)
	require.NoError(t, provider.Start())
	t.Cleanup(func() {
		provider.Stop()
		resumeNc.Close()
	})
	require.NoError(t, resumeNc.Flush())

	waitForPhotoCount(t, resumeDb, "physical-photos", 3)

	// still exactly one document per file, never two, despite reprocessing
	for _, path := range []string{"/mounted/photos/holidays/a.jpg", "/mounted/photos/holidays/b.jpg", "/mounted/photos/holidays/c.jpg"} {
		count, err := db.Collection("galleryPhotos").CountDocuments(context.Background(), bson.M{
			"providerId": "physical-photos",
			"path":       path,
		})
		require.NoError(t, err)
		assert.Equal(t, int64(1), count, "duplicate document for %s after resumed backfill", path)
	}
}

// TestNestedFolderDoesNotDoubleBackfilledPhotos covers: adding a folder
// nested inside an already-configured (and already backfilled) folder must
// not double-count its photos in the listing, because the nested folder's
// own backfill walks the same physical files again.
func TestNestedFolderDoesNotDoubleBackfilledPhotos(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	stub := newStubFileIndex(t, nc, 0)
	outerEntries := withProvider("physical-photos", []events.FileIndexListEntry{
		fileEntry("/mounted/photos/holidays/nested/shared.jpg", 1, 1000, "image/jpeg"),
		fileEntry("/mounted/photos/holidays/top.jpg", 1, 1000, "image/jpeg"),
	})
	stub.set("physical-photos", "/mounted/photos/holidays", outerEntries)

	nestedEntries := withProvider("physical-photos", []events.FileIndexListEntry{
		fileEntry("/mounted/photos/holidays/nested/shared.jpg", 1, 1000, "image/jpeg"),
	})
	stub.set("physical-photos", "/mounted/photos/holidays/nested", nestedEntries)

	outer := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	require.Equal(t, "", outer.Error)
	waitForPhotoCount(t, db, "physical-photos", 2)

	nested := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays/nested",
	})
	require.Equal(t, "", nested.Error)

	// give the nested folder's backfill time to run - it should upsert the
	// shared file again, not add a second document
	waitForCondition(t, func() bool {
		return stub.requestCount() >= 2
	}, "expected the nested folder's own backfill request to have been issued")

	// settle briefly, then assert the read model still holds exactly one
	// document for the shared physical file and exactly two documents total
	time.Sleep(300 * time.Millisecond)

	count, err := db.Collection("galleryPhotos").CountDocuments(context.Background(), bson.M{
		"providerId": "physical-photos",
		"path":       "/mounted/photos/holidays/nested/shared.jpg",
	})
	require.NoError(t, err)
	assert.Equal(t, int64(1), count, "a file covered by both an outer and nested folder must be one document")

	total, err := db.Collection("galleryPhotos").CountDocuments(context.Background(), bson.M{"providerId": "physical-photos"})
	require.NoError(t, err)
	assert.Equal(t, int64(2), total)

	// and the listing (which is what "doubling in the listing" is actually
	// about) shows exactly two items, not three
	listRes := list(t, nc, &gallery.GalleryListRequest{UserId: "pino"})
	require.Equal(t, "", listRes.Error)
	assert.Len(t, listRes.Items, 2)
}

// TestBackfillNeverContactsFileProvider covers the ticket's "reads the
// index, never the File Provider" constraint directly: backfilling a folder
// whose files are only known to the (stubbed) File Index - with no File
// Provider running at all - must still succeed, proving backfill never
// tries to open the files it backfills.
func TestBackfillNeverContactsFileProvider(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	// deliberately no startFileProvider call: if backfill ever tried to open
	// a file through fileprovider.FileProviderClient, that request would
	// simply time out with no responder, and the photo would never appear -
	// this test would fail, not hang, because waitForPhotoCount has its own
	// bounded deadline.
	stub := newStubFileIndex(t, nc, 0)
	stub.set("physical-photos", "/mounted/photos/holidays", withProvider("physical-photos", []events.FileIndexListEntry{
		fileEntry("/mounted/photos/holidays/ghost.jpg", 1, 1000, "image/jpeg"),
	}))

	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	require.Equal(t, "", res.Error)

	waitForPhotoCount(t, db, "physical-photos", 1)

	photo := findPhoto(t, db, "physical-photos", "/mounted/photos/holidays/ghost.jpg")
	require.NotNil(t, photo)
	assert.True(t, photo.MetadataPending)
	assert.Equal(t, 0, photo.Width)
	assert.Equal(t, 0, photo.Height)
}

// TestBackfillDoesNotDowngradeALiveHealedItem covers the invariant that
// backfill data must never overwrite better data that is already present.
//
// Backfill can only ever produce rung-two (modification time) Capture Dates
// and zero dimensions, so once a live event has healed a document with real
// EXIF, any subsequent backfill pass touching the same physical key must
// leave it completely alone. Getting this wrong is uniquely nasty because it
// is invisible: the photo keeps metadataPending false while silently sorting
// to its modification-time position forever, which is precisely the
// "modification time is not an acceptable ordering key" failure the Capture
// Date chain exists to prevent.
//
// Both routes that can re-touch an already-healed key are covered:
// (a) a restart resuming a backfill whose earlier page was already healed,
// and (b) a nested folder's own backfill re-walking a file an outer folder
// already covered.
func TestBackfillDoesNotDowngradeALiveHealedItem(t *testing.T) {
	exifCapturedAt := time.Date(2007, 8, 9, 10, 11, 12, 0, time.UTC).Unix()
	// a deliberately much LATER modification time, so a downgrade moves the
	// photo to a visibly wrong position rather than being indistinguishable
	backfillModTime := time.Date(2024, 1, 1, 0, 0, 0, 0, time.UTC).Unix()

	// healLive writes an EXIF fixture through the File Provider and publishes
	// a live "created" event for it, waiting until the read model shows the
	// document healed to a real EXIF Capture Date.
	healLive := func(t *testing.T, nc *nats.Conn, db *mongo.Database, dir string, physicalPath string) {
		t.Helper()
		data := buildJPEGWithExif(t, 12, 8, "2007:08:09 10:11:12", 1)
		writeFixture(t, dir, physicalPath, data)
		publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventCreated, int64(len(data)), backfillModTime, "image/jpeg")

		waitForCondition(t, func() bool {
			p := findPhoto(t, db, "physical-photos", physicalPath)
			return p != nil && p.CapturedAtSource == gallery.CaptureDateSourceExif
		}, "the live event never healed the backfilled placeholder to an EXIF Capture Date")
	}

	// assertStillHealed is the actual regression assertion, shared by both
	// sub-tests: the document must look exactly as the live event left it.
	assertStillHealed := func(t *testing.T, db *mongo.Database, physicalPath string) {
		t.Helper()
		p := findPhoto(t, db, "physical-photos", physicalPath)
		require.NotNil(t, p)
		assert.Equal(t, gallery.CaptureDateSourceExif, p.CapturedAtSource,
			"backfill downgraded a live-healed item back to modification time")
		assert.Equal(t, exifCapturedAt, p.CapturedAt,
			"backfill overwrote a real EXIF Capture Date with the File Index modification time")
		assert.False(t, p.MetadataPending)
		// the rest of the live extraction must survive untouched too
		assert.Equal(t, 12, p.Width)
		assert.Equal(t, 8, p.Height)
	}

	t.Run("resumed backfill re-walking an already-healed page", func(t *testing.T) {
		nc, db := startGalleryProvider(t, map[string][]string{
			"pino": {"photos"},
		})
		clearSourceFolders(t, db)
		clearPhotos(t, db)

		dir := startFileProvider(t, "physical-photos")

		physicalPath := "/mounted/photos/holidays/healed.jpg"
		stub := newStubFileIndex(t, nc, 1)
		stub.set("physical-photos", "/mounted/photos/holidays", withProvider("physical-photos", []events.FileIndexListEntry{
			fileEntry(physicalPath, 999, backfillModTime, "image/jpeg"),
			fileEntry("/mounted/photos/holidays/other.jpg", 1, backfillModTime, "image/jpeg"),
		}))

		res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
			Operation:       gallery.GallerySourceFolderOperationAdd,
			UserId:          "pino",
			SpaceProviderId: "photos",
			Path:            "/holidays",
		})
		require.Equal(t, "", res.Error)
		folderId := res.SourceFolder[0].Id

		waitForPhotoCount(t, db, "physical-photos", 2)

		// a live event heals the first page's file with real EXIF
		healLive(t, nc, db, dir, physicalPath)

		// now simulate a restart that resumes this folder's backfill from the
		// very beginning - the worst case, since it guarantees the healed key
		// is walked again
		_, err := db.Collection("gallerySourceFolders").UpdateByID(context.Background(), folderId, bson.M{
			"$set": bson.M{"backfillDone": false, "backfillCursor": ""},
		})
		require.NoError(t, err)

		before := stub.requestCount()

		provider, resumeNc, _ := getGalleryProvider(t)
		require.NoError(t, provider.Start())
		t.Cleanup(func() {
			provider.Stop()
			resumeNc.Close()
		})
		require.NoError(t, resumeNc.Flush())

		// wait until the resumed backfill has actually re-walked every page,
		// so the assertion below is about a completed re-pass and not a race
		waitForCondition(t, func() bool {
			return stub.requestCount() >= before+2
		}, "the resumed backfill never re-walked the healed page")
		waitForCondition(t, func() bool {
			var f gallery.GallerySourceFolder
			err := db.Collection("gallerySourceFolders").FindOne(context.Background(), bson.M{"_id": folderId}).Decode(&f)
			require.NoError(t, err)
			return f.BackfillDone
		}, "the resumed backfill never ran to completion")

		assertStillHealed(t, db, physicalPath)
	})

	t.Run("nested folder backfill re-walking an already-healed file", func(t *testing.T) {
		nc, db := startGalleryProvider(t, map[string][]string{
			"pino": {"photos"},
		})
		clearSourceFolders(t, db)
		clearPhotos(t, db)

		dir := startFileProvider(t, "physical-photos")

		physicalPath := "/mounted/photos/holidays/nested/shared.jpg"
		stub := newStubFileIndex(t, nc, 0)
		stub.set("physical-photos", "/mounted/photos/holidays", withProvider("physical-photos", []events.FileIndexListEntry{
			fileEntry(physicalPath, 999, backfillModTime, "image/jpeg"),
		}))
		stub.set("physical-photos", "/mounted/photos/holidays/nested", withProvider("physical-photos", []events.FileIndexListEntry{
			fileEntry(physicalPath, 999, backfillModTime, "image/jpeg"),
		}))

		outer := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
			Operation:       gallery.GallerySourceFolderOperationAdd,
			UserId:          "pino",
			SpaceProviderId: "photos",
			Path:            "/holidays",
		})
		require.Equal(t, "", outer.Error)
		waitForPhotoCount(t, db, "physical-photos", 1)

		// a live event heals the shared file with real EXIF
		healLive(t, nc, db, dir, physicalPath)

		// adding the nested folder backfills the very same physical file
		// again, through a completely separate Gallery Source Folder with its
		// own cursor - nothing about backfill's own paging can protect this
		// case, so the upsert itself has to
		before := stub.requestCount()
		nested := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
			Operation:       gallery.GallerySourceFolderOperationAdd,
			UserId:          "pino",
			SpaceProviderId: "photos",
			Path:            "/holidays/nested",
		})
		require.Equal(t, "", nested.Error)

		nestedId := nested.SourceFolder[0].Id
		waitForCondition(t, func() bool {
			return stub.requestCount() > before
		}, "the nested folder's backfill never issued its File Index request")
		waitForCondition(t, func() bool {
			var f gallery.GallerySourceFolder
			err := db.Collection("gallerySourceFolders").FindOne(context.Background(), bson.M{"_id": nestedId}).Decode(&f)
			require.NoError(t, err)
			return f.BackfillDone
		}, "the nested folder's backfill never ran to completion")

		assertStillHealed(t, db, physicalPath)

		// and still exactly one document, as the nested-folder test asserts
		count, err := db.Collection("galleryPhotos").CountDocuments(context.Background(), bson.M{
			"providerId": "physical-photos",
			"path":       physicalPath,
		})
		require.NoError(t, err)
		assert.Equal(t, int64(1), count)
	})
}
