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
	"go.mongodb.org/mongo-driver/bson/primitive"
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

	// dirEventCount counts only FileInfoEvents for DIRECTORIES, which is a
	// direct, noise-free count of "how many times has a directory been
	// listed by a walk". Nothing else in the system produces one: the File
	// Provider publishes a FileInfoEvent from exactly two places, Readdir
	// (server_file.go) and Stat (server.go), and gallery's own ingestion
	// path only ever OpenFiles a photo - which is lazy client-side and
	// Stats nothing (see fileprovider client.OpenFile). So every directory
	// event observed here was caused by a rescan walk listing that
	// directory's parent, and by nothing else.
	//
	// This is what makes TestRescanTwiceInQuickSuccessionRunsOneScan able to
	// tell one walk from two: a second walk re-lists the folder root, which
	// re-emits an event for every subdirectory under it.
	dirEventCount int
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
		s.mu.Lock()
		s.dirEventCount++
		s.mu.Unlock()
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

func (s *stubFileIndexer) dirEvents() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.dirEventCount
}

// waitTight polls cond at 1ms, unlike waitForCondition's 50ms. Needed where
// the test must react while a background walk is still in flight rather than
// merely observe that it eventually happened - a 50ms sampling interval is a
// large fraction of a walk and would make such a test needlessly racy.
func waitTight(t *testing.T, cond func() bool, msg string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal(msg)
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

// rescanRaceSubdirs is how many subdirectories TestRescanTwiceInQuickSuccession
// RunsOneScan puts under the folder root. It exists to make the first walk
// take long enough that the second RESCAN provably lands while it is still in
// flight: each subdirectory costs the walk an OpenFile + Readdir + Close round
// trip through the File Provider, so a few hundred of them run to hundreds of
// milliseconds, against the ~1ms it takes the test to fire the second request
// once it has seen the first directory event.
const rescanRaceSubdirs = 200

// TestRescanTwiceInQuickSuccessionRunsOneScan covers: firing RESCAN twice
// back to back for the same folder must not run two concurrent walks. The
// second request observes the first one already in flight (RescanRunning is
// already true) and does not start a second walk of its own.
//
// Asserting this needs an observable that can COUNT walks, because RESCAN's
// reply is deliberately identical either way (it reports RescanRunning=true
// whether this call started the walk or merely found one already running).
// The stub file-indexer's directory-event count is that observable: a walk
// lists the folder root exactly once, emitting one FileInfoEvent per
// subdirectory under it, so one walk means rescanRaceSubdirs directory events
// and two walks means twice that. Nothing else in the system emits directory
// events - see stubFileIndexer.dirEventCount.
//
// Without the guard in startRescan this test fails with exactly 2x the
// expected count, which is what makes it worth its runtime.
func TestRescanTwiceInQuickSuccessionRunsOneScan(t *testing.T) {
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

	// a wide, shallow tree: one directory per photo, so the walk spends most
	// of its time on directory round trips rather than on ingestion
	for i := 0; i < rescanRaceSubdirs; i++ {
		data := buildPNG(t, 4, 4)
		writeFixture(t, dir, fmt.Sprintf("/mounted/photos/holidays/sub%03d/pic.png", i), data)
	}

	first := rescan(t, nc, "pino", folderId.Hex())
	require.Equal(t, "", first.Error)
	require.True(t, first.SourceFolder[0].RescanRunning)

	// the first walk has listed the root and is now descending into the
	// subdirectories - it is unambiguously in flight
	waitTight(t, func() bool {
		return stub.dirEvents() > 0
	}, "the first rescan never started walking")

	second := rescan(t, nc, "pino", folderId.Hex())
	require.Equal(t, "", second.Error)
	// still reported running - RESCAN is idempotent while a scan is already
	// in flight, not an error
	require.True(t, second.SourceFolder[0].RescanRunning)

	waitForRescanFinished(t, db, folderId)
	// settle, so a wrongly-started second walk has time to show up
	time.Sleep(500 * time.Millisecond)

	assert.Equal(t, rescanRaceSubdirs, stub.dirEvents(),
		"the folder root was listed more than once: a second concurrent walk was started")

	// and the result is still one photo per subdirectory, not two of each
	waitForPhotoCount(t, db, "physical-photos", rescanRaceSubdirs)

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

// primeRescanBaseline runs one full rescan of folderId and waits for it to
// finish, so that afterwards the stub file-indexer's "known" state matches
// what is on disk exactly - the same state the real file-indexer would hold
// once it has indexed a folder.
//
// Every test below that wants to isolate RESCAN's HEALING pass
// (healPendingMetadata) from its WALK needs this. Without it, the walk's very
// first FileInfoEvent for a file is "new" to the indexer, which publishes a
// FileChangedEvent, which ingest.go's upsertPhoto happily processes - so a
// test asserting "the placeholder got healed" would pass even if
// healPendingMetadata did nothing at all. After priming, a second walk over
// unchanged bytes produces no FileChangedEvent whatsoever, leaving the
// healing pass as the only thing that can possibly touch the document.
func primeRescanBaseline(t *testing.T, nc *nats.Conn, db *mongo.Database, userId string, folderId primitive.ObjectID) {
	t.Helper()
	res := rescan(t, nc, userId, folderId.Hex())
	require.Equal(t, "", res.Error)
	waitForRescanFinished(t, db, folderId)
}

// TestRescanHealsMetadataPendingPhotos covers ticket 08's gap: a photo
// backfilled from the File Index (MetadataPending, rung-two Capture Date, no
// dimensions) whose bytes are UNTOUCHED on disk never receives a
// FileChangedEvent from a plain walk - file-indexer only republishes on a
// new/changed entry (see stubFileIndexer's docs) - so RESCAN's healing pass
// (healPendingMetadata) is what is actually responsible for curing it, not
// the walk.
//
// The baseline rescan (see primeRescanBaseline) is what makes that claim
// testable rather than merely asserted: by the time the placeholder is
// written, the indexer already knows this file, so the second rescan's walk
// is provably silent and only the healing pass remains.
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
	writeFixture(t, dir, physicalPath, data)

	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	require.Equal(t, "", res.Error)
	folderId := res.SourceFolder[0].Id

	primeRescanBaseline(t, nc, db, "pino", folderId)
	waitForPhoto(t, db, "physical-photos", physicalPath)

	// Overwrite the document with exactly what backfill would have left
	// behind for a stale File Index entry: rung-two Capture Date, no
	// dimensions, MetadataPending. Bypasses backfill itself (which needs a
	// stubbed File Index) since this test is about RESCAN's healing pass.
	_, err := db.Collection("galleryPhotos").UpdateOne(context.Background(),
		bson.M{"providerId": "physical-photos", "path": physicalPath},
		bson.M{"$set": bson.M{
			"capturedAt":       time.Date(2010, 1, 1, 0, 0, 0, 0, time.UTC).Unix(),
			"capturedAtSource": gallery.CaptureDateSourceModTime,
			"width":            0,
			"height":           0,
			"orientation":      0,
			"metadataPending":  true,
		}})
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

// TestRescanDoesNotResurrectADeletedPendingPhoto guards the one way the
// healing pass could have reintroduced the defect ticket 08's rework fixed in
// backfillUpsert: markDeleted (ingest.go) sets deleted:true but leaves
// metadataPending alone, so a backfilled placeholder whose file was later
// deleted sits in the read model as (deleted:true, metadataPending:true)
// forever. If healPendingMetadata selected on metadataPending alone it would
// pick that document up and run it through upsertPhoto, which unconditionally
// writes deleted:false - resurrecting a tombstoned photo with no live event
// authorising it.
//
// The file is deliberately left readable on disk, so extraction WOULD succeed:
// the guard, not an incidental "the file is gone" failure, is what has to keep
// the tombstone intact.
func TestRescanDoesNotResurrectADeletedPendingPhoto(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	dir := startFileProvider(t, "physical-photos")
	newStubFileIndexer(t, nc)

	physicalPath := "/mounted/photos/holidays/tombstoned.jpg"
	data := buildJPEGWithExif(t, 10, 10, "2019:03:03 03:03:03", 0)
	writeFixture(t, dir, physicalPath, data)

	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	require.Equal(t, "", res.Error)
	folderId := res.SourceFolder[0].Id

	primeRescanBaseline(t, nc, db, "pino", folderId)
	waitForPhoto(t, db, "physical-photos", physicalPath)

	// the state markDeleted leaves behind on a never-healed backfill
	// placeholder: tombstoned, but still flagged MetadataPending
	_, err := db.Collection("galleryPhotos").UpdateOne(context.Background(),
		bson.M{"providerId": "physical-photos", "path": physicalPath},
		bson.M{"$set": bson.M{"deleted": true, "metadataPending": true}})
	require.NoError(t, err)

	before := findPhoto(t, db, "physical-photos", physicalPath)
	require.NotNil(t, before)

	rescanRes := rescan(t, nc, "pino", folderId.Hex())
	require.Equal(t, "", rescanRes.Error)
	waitForRescanFinished(t, db, folderId)

	// settle, so a wrongly-issued heal has time to land
	time.Sleep(300 * time.Millisecond)

	after := findPhoto(t, db, "physical-photos", physicalPath)
	require.NotNil(t, after)
	assert.True(t, after.Deleted, "RESCAN must not resurrect a tombstoned photo")
	assert.True(t, after.MetadataPending, "a tombstoned photo has no metadata worth healing")
	assert.Equal(t, before.Seq, after.Seq, "RESCAN must not have written to the tombstoned document at all")

	// and it stays invisible in the listing
	listRes := list(t, nc, &gallery.GalleryListRequest{UserId: "pino"})
	require.Equal(t, "", listRes.Error)
	assert.Len(t, listRes.Items, 0)
}
