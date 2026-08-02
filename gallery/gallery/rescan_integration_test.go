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
	"fmt"
	"mime"
	"path"
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

// stubFileIndexer is a minimal stand-in for the real file-indexer service: it
// subscribes to the same FileInfoEvent topic the File Provider publishes on
// (events.FileProviderFileInfoTopic) and, for every entry that is new or
// whose ModTime/Size differs from what it last saw, publishes a
// FileChangedEvent on the same durable stream/subject the real file-indexer
// uses (events.FileChangedTopic) - exactly the "new or changed" rule
// file-indexer's own upsertFile implements (see
// file-indexer/fileindexer/consumer.go). This is what lets these tests prove
// RESCAN's walk (walkRescan in rescan.go) really does cause file-indexer-like
// behaviour end to end - a FileInfoEvent in, a FileChangedEvent out for
// anything actually new - without pulling in file-indexer's own MongoDB-backed
// implementation, which is out of scope for a test at the GALLERY service's
// NATS boundary.
//
// A file/directory that this stub has already seen with an identical
// (size, modTime) produces NO FileChangedEvent - mirroring file-indexer's
// real "unchanged" path - which is what makes
// TestRescanOfUpToDateFolderChangesNothing meaningful: if the stub were
// looser than the real service, that test could pass for the wrong reason.
type stubFileIndexer struct {
	t  *testing.T
	nc *nats.Conn

	mu    sync.Mutex
	known map[string]stubFileIndexerRecord

	// fileInfoEventCount counts every FileInfoEvent observed, directories
	// included - used to assert the walk actually visited the tree, since a
	// no-op rescan on an already up to date folder still causes every entry
	// to be re-Stat'd/re-Readdir'd even though nothing downstream changes.
	fileInfoEventCount int
}

type stubFileIndexerRecord struct {
	size    int64
	modTime int64
}

func newStubFileIndexer(t *testing.T, nc *nats.Conn) *stubFileIndexer {
	t.Helper()
	s := &stubFileIndexer{
		t:     t,
		nc:    nc,
		known: make(map[string]stubFileIndexerRecord),
	}

	sub, err := nc.Subscribe(events.FileProviderFileInfoTopic, func(msg *nats.Msg) {
		ev := events.FileInfoEvent{}
		if err := ev.Unmarshal(msg.Data); err != nil {
			return
		}
		s.handle(ev)
	})
	require.NoError(t, err)
	t.Cleanup(func() { sub.Unsubscribe() })

	require.NoError(t, nc.Flush())

	return s
}

func (s *stubFileIndexer) handle(ev events.FileInfoEvent) {
	s.mu.Lock()
	s.fileInfoEventCount++
	key := ev.ProviderID + "\x00" + ev.Path
	prior, seen := s.known[key]
	record := stubFileIndexerRecord{size: ev.Size, modTime: ev.ModTime}
	s.known[key] = record
	s.mu.Unlock()

	if ev.IsDir {
		// gallery ingestion only ever cares about files - see
		// ingestConsumer.handleMessage's IsDir check - so the real
		// file-indexer would still publish a FileChangedEvent for a changed
		// directory, but nothing downstream would act on it. Skipping it
		// here keeps the stub's job honest (prove files are (re)detected)
		// without asserting behaviour that is genuinely irrelevant.
		return
	}

	changed := !seen || prior.size != record.size || prior.modTime != record.modTime
	if !changed {
		return
	}

	change := events.FileChangedEventChanged
	if !seen {
		change = events.FileChangedEventCreated
	}

	typ := mime.TypeByExtension(path.Ext(ev.Path))

	fileEv := events.FileChangedEvent{
		Event:      events.Event{ID: uuid.NewString(), Version: 1},
		FileID:     uuid.NewString(),
		ProviderID: ev.ProviderID,
		Change:     change,
		Path:       ev.Path,
		Size:       ev.Size,
		ModTime:    ev.ModTime,
		Mime:       typ,
	}
	data, err := fileEv.Marshal()
	if err != nil {
		s.t.Errorf("stubFileIndexer: failed to marshal FileChangedEvent: %v", err)
		return
	}
	topic := fmt.Sprintf(events.FileChangedTopicPattern, fileEv.FileID)
	if err := s.nc.Publish(topic, data); err != nil {
		s.t.Errorf("stubFileIndexer: failed to publish FileChangedEvent: %v", err)
	}
}

func (s *stubFileIndexer) fileInfoEvents() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.fileInfoEventCount
}

// rescan issues a RESCAN request for folderId, owned by userId.
func rescan(t *testing.T, nc *nats.Conn, userId string, folderId string) *gallery.GallerySourceFolderCrudResponse {
	t.Helper()
	return crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationRescan,
		UserId:    userId,
		Id:        folderId,
	})
}

func waitForRescanFinished(t *testing.T, db *mongo.Database, folderId any) {
	t.Helper()
	waitForCondition(t, func() bool {
		var f gallery.GallerySourceFolder
		err := db.Collection("gallerySourceFolders").FindOne(context.Background(), bson.M{"_id": folderId}).Decode(&f)
		require.NoError(t, err)
		return !f.RescanRunning
	}, "rescan never finished (RescanRunning stayed true)")
}

// TestRescanFindsPhotosMissingFromIndex is the ticket's core requirement:
// a photo written directly to disk - never announced through any
// FileChangedEvent, standing in for "the File Index is stale" - is
// discovered and appears in the gallery once RESCAN walks the real File
// Provider tree, proving this is a genuine re-scan and not a re-read of the
// (here: entirely absent) index.
func TestRescanFindsPhotosMissingFromIndex(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	dir := startFileProvider(t, "physical-photos")
	newStubFileIndexer(t, nc)

	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	require.Equal(t, "", res.Error)
	folderId := res.SourceFolder[0].Id

	// written straight to disk: no FileChangedEvent, no File Index entry -
	// exactly "photos copied in over SMB that never showed up" from the
	// ticket's own framing
	data := buildJPEGWithExif(t, 16, 12, "2022:05:04 09:08:07", 0)
	physicalPath := "/mounted/photos/holidays/untracked.jpg"
	writeFixture(t, dir, physicalPath, data)

	rescanRes := rescan(t, nc, "pino", folderId.Hex())
	require.Equal(t, "", rescanRes.Error)
	require.Len(t, rescanRes.SourceFolder, 1)
	assert.True(t, rescanRes.SourceFolder[0].RescanRunning, "RESCAN response should report the walk as running")

	photo := waitForPhoto(t, db, "physical-photos", physicalPath)
	assert.Equal(t, gallery.CaptureDateSourceExif, photo.CapturedAtSource)
	assert.Equal(t, 16, photo.Width)
	assert.False(t, photo.MetadataPending)

	waitForRescanFinished(t, db, folderId)

	listRes := list(t, nc, &gallery.GalleryListRequest{UserId: "pino"})
	require.Equal(t, "", listRes.Error)
	assert.Len(t, listRes.Items, 1)
}

// TestRescanOfUpToDateFolderChangesNothing covers: rescanning a folder whose
// disk contents exactly match what is already in the gallery produces no
// duplicates and leaves the existing document untouched - the walk still
// happens (files are still Stat/Readdir'd - see the fileInfoEvents assertion)
// but nothing downstream reacts to it, because nothing actually changed.
func TestRescanOfUpToDateFolderChangesNothing(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	dir := startFileProvider(t, "physical-photos")
	stub := newStubFileIndexer(t, nc)

	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	require.Equal(t, "", res.Error)
	folderId := res.SourceFolder[0].Id

	data := buildJPEGWithExif(t, 8, 8, "2018:01:01 00:00:00", 0)
	physicalPath := "/mounted/photos/holidays/steady.jpg"
	writeFixture(t, dir, physicalPath, data)

	// bring the photo in through a FIRST rescan, so the stub file-indexer's
	// "known" state (populated from the FileInfoEvents this walk causes)
	// genuinely reflects what is on disk - exactly what the real
	// file-indexer's own persisted state would reflect after a first
	// walk/scan. Using publishFileChanged directly here instead would starve
	// the stub of the FileInfoEvent that establishes its baseline, making the
	// SECOND rescan look like it found something "new" for the wrong reason
	// (the stub had never seen the file, not because the file actually
	// changed).
	first := rescan(t, nc, "pino", folderId.Hex())
	require.Equal(t, "", first.Error)
	original := waitForPhoto(t, db, "physical-photos", physicalPath)
	originalSeq := original.Seq
	waitForRescanFinished(t, db, folderId)

	rescanRes := rescan(t, nc, "pino", folderId.Hex())
	require.Equal(t, "", rescanRes.Error)

	waitForCondition(t, func() bool {
		return stub.fileInfoEvents() > 1
	}, "the second rescan never walked the folder (no further FileInfoEvent observed)")

	waitForRescanFinished(t, db, folderId)

	// settle briefly so a wrongly-triggered re-upsert has time to land
	time.Sleep(300 * time.Millisecond)

	count, err := db.Collection("galleryPhotos").CountDocuments(context.Background(), bson.M{
		"providerId": "physical-photos",
		"path":       physicalPath,
	})
	require.NoError(t, err)
	assert.Equal(t, int64(1), count, "rescanning an up to date folder must not produce a duplicate")

	unchanged := findPhoto(t, db, "physical-photos", physicalPath)
	require.NotNil(t, unchanged)
	assert.Equal(t, originalSeq, unchanged.Seq, "rescanning an up to date folder must not touch the existing document")
}

// TestRescanTwiceInQuickSuccessionRunsOneScan covers: firing RESCAN twice
// back to back for the same folder must not run two concurrent walks. The
// second request observes the first one already in flight (RescanRunning is
// already true) and does not start a second walk of its own.
func TestRescanTwiceInQuickSuccessionRunsOneScan(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	dir := startFileProvider(t, "physical-photos")
	newStubFileIndexer(t, nc)

	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	require.Equal(t, "", res.Error)
	folderId := res.SourceFolder[0].Id

	// give the walk something to take a moment over
	for i := 0; i < 5; i++ {
		data := buildPNG(t, 4, 4)
		writeFixture(t, dir, fmt.Sprintf("/mounted/photos/holidays/pic%d.png", i), data)
	}

	first := rescan(t, nc, "pino", folderId.Hex())
	require.Equal(t, "", first.Error)
	require.True(t, first.SourceFolder[0].RescanRunning)

	second := rescan(t, nc, "pino", folderId.Hex())
	require.Equal(t, "", second.Error)
	// still just one folder document, still reported running - RESCAN is
	// idempotent while a scan is already in flight, not an error
	require.True(t, second.SourceFolder[0].RescanRunning)

	waitForRescanFinished(t, db, folderId)

	// exactly one gallerySourceFolders document throughout - RESCAN never
	// creates state of its own per request
	count, err := db.Collection("gallerySourceFolders").CountDocuments(context.Background(), bson.M{"_id": folderId})
	require.NoError(t, err)
	assert.Equal(t, int64(1), count)
}

// TestRescanDoesNotBlockGalleryQueries covers: a rescan in flight over a
// folder must not prevent LIST from answering - the walk runs entirely in
// the background, sharing no lock with query handling.
func TestRescanDoesNotBlockGalleryQueries(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	dir := startFileProvider(t, "physical-photos")
	stub := newStubFileIndexer(t, nc)

	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	require.Equal(t, "", res.Error)
	folderId := res.SourceFolder[0].Id

	for i := 0; i < 20; i++ {
		data := buildPNG(t, 4, 4)
		writeFixture(t, dir, fmt.Sprintf("/mounted/photos/holidays/pic%d.png", i), data)
	}

	rescanRes := rescan(t, nc, "pino", folderId.Hex())
	require.Equal(t, "", rescanRes.Error)
	require.True(t, rescanRes.SourceFolder[0].RescanRunning)

	// query answered promptly while the rescan is (very likely) still
	// walking - this is a best-effort timing assertion like
	// TestAddReturnsPromptlyWhileBackfillRunsInBackground, not a hard
	// guarantee the walk is still in flight at this exact instant
	start := time.Now()
	listRes := list(t, nc, &gallery.GalleryListRequest{UserId: "pino"})
	elapsed := time.Since(start)
	require.Equal(t, "", listRes.Error)
	assert.Less(t, elapsed, 2*time.Second, "LIST must not be blocked by an in-flight rescan")

	waitForRescanFinished(t, db, folderId)

	// the walk genuinely ran to completion in the background - all 20 files
	// were discovered, not just the query answered quickly for lack of work
	waitForPhotoCount(t, db, "physical-photos", 20)
	assert.GreaterOrEqual(t, stub.fileInfoEvents(), 20, "the walk should have visited every file")
}

// TestRescanIsScopedToOwningUser covers: a user cannot trigger a rescan of
// another user's folder by guessing its id, mirroring
// TestSourceFoldersAreScopedPerUser's coverage of REMOVE.
func TestRescanIsScopedToOwningUser(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
		"lino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	added := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	require.Equal(t, "", added.Error)

	stolen := rescan(t, nc, "lino", added.SourceFolder[0].Id.Hex())
	assert.NotEqual(t, "", stolen.Error)
}

// TestRescanHealsMetadataPendingPhotos covers ticket 08's gap: a photo
// backfilled from the File Index (MetadataPending, rung-two Capture Date, no
// dimensions) whose bytes are UNTOUCHED on disk never receives a
// FileChangedEvent from a plain walk - file-indexer only republishes on a
// new/changed entry (see stubFileIndexer's docs) - so RESCAN's healing pass
// (healPendingMetadata) is what is actually responsible for curing it, not
// the walk.
func TestRescanHealsMetadataPendingPhotos(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	dir := startFileProvider(t, "physical-photos")
	newStubFileIndexer(t, nc)

	physicalPath := "/mounted/photos/holidays/pending.jpg"
	data := buildJPEGWithExif(t, 20, 15, "2016:02:02 02:02:02", 3)
	// the file already exists on disk with its FINAL bytes before the folder
	// is ever added - so its FileInfoEvent's (size, modTime) never changes
	// across the rescan, and the stub file-indexer (like the real one) never
	// emits a FileChangedEvent for it
	writeFixture(t, dir, physicalPath, data)

	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	require.Equal(t, "", res.Error)
	folderId := res.SourceFolder[0].Id

	// simulate backfill having already placed a MetadataPending placeholder
	// for this file, as it would from a stale File Index entry - bypassing
	// backfill itself (which needs a stubbed File Index) since this test is
	// about RESCAN's healing pass, not backfill
	_, err := db.Collection("galleryPhotos").InsertOne(context.Background(), bson.M{
		"providerId":       "physical-photos",
		"path":             physicalPath,
		"capturedAt":       time.Date(2010, 1, 1, 0, 0, 0, 0, time.UTC).Unix(),
		"capturedAtSource": gallery.CaptureDateSourceModTime,
		"size":             int64(len(data)),
		"mime":             "image/jpeg",
		"deleted":          false,
		"indexedAt":        time.Now().Unix(),
		"width":            0,
		"height":           0,
		"orientation":      0,
		"unsupported":      "",
		"metadataPending":  true,
		"seq":              int64(1),
	})
	require.NoError(t, err)

	rescanRes := rescan(t, nc, "pino", folderId.Hex())
	require.Equal(t, "", rescanRes.Error)

	waitForCondition(t, func() bool {
		p := findPhoto(t, db, "physical-photos", physicalPath)
		return p != nil && !p.MetadataPending
	}, "RESCAN never healed the MetadataPending placeholder")

	healed := findPhoto(t, db, "physical-photos", physicalPath)
	require.NotNil(t, healed)
	assert.Equal(t, gallery.CaptureDateSourceExif, healed.CapturedAtSource)
	assert.Equal(t, 20, healed.Width)
	assert.Equal(t, 15, healed.Height)
	assert.Equal(t, 3, healed.Orientation)

	waitForRescanFinished(t, db, folderId)
}
