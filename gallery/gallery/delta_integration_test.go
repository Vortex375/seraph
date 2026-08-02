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
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/spaces/spaces"
)

// clearPendingTombstones empties galleryPendingTombstones between tests,
// exactly like clearSourceFolders/clearPhotos - REMOVE's tombstone sweep
// (recordRemovalTombstones, delta.go) writes here, and it is not scoped by
// any per-test database name, so it must be reset the same way.
func clearPendingTombstones(t *testing.T, db *mongo.Database) {
	t.Helper()
	_, err := db.Collection("galleryPendingTombstones").DeleteMany(context.Background(), bson.M{})
	require.NoError(t, err)
}

// delta issues one GalleryDeltaRequest and returns its response, following
// the same thin-wrapper convention as list (query_integration_test.go) and
// crud (gallery_integration_test.go).
func delta(t *testing.T, nc *nats.Conn, req *gallery.GalleryDeltaRequest) *gallery.GalleryDeltaResponse {
	t.Helper()
	res := gallery.GalleryDeltaResponse{}
	err := messaging.Request(context.Background(), nc, gallery.GalleryDeltaTopic, messaging.Json(req), messaging.Json(&res))
	require.NoError(t, err)
	return &res
}

// deltaAll drains every page of a poll starting at since, following
// NextCursor until HasMore is false, and returns the concatenated items
// together with the final NextSince - the shape a real client would use to
// finish one full poll before persisting its new cursor.
func deltaAll(t *testing.T, nc *nats.Conn, userId string, since int64) ([]gallery.GalleryDeltaItem, int64) {
	t.Helper()
	items := make([]gallery.GalleryDeltaItem, 0)
	cursor := ""
	for {
		res := delta(t, nc, &gallery.GalleryDeltaRequest{UserId: userId, Since: since, Cursor: cursor})
		require.Equal(t, "", res.Error)
		items = append(items, res.Items...)
		if !res.HasMore {
			return items, res.NextSince
		}
		cursor = res.NextCursor
	}
}

// createPhoto publishes a "created" FileChangedEvent for a fresh EXIF JPEG
// fixture at physicalPath and waits for it to land in the read model,
// returning the resulting document (which by now carries its allocated
// Seq).
func createPhoto(t *testing.T, nc *nats.Conn, db *mongo.Database, dir, providerId, physicalPath string) *gallery.GalleryPhoto {
	t.Helper()
	data := buildJPEGWithExif(t, 12, 8, "2019:01:01 00:00:00", 0)
	writeFixture(t, dir, physicalPath, data)
	publishFileChanged(t, nc, providerId, physicalPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")
	return waitForPhoto(t, db, providerId, physicalPath)
}

// TestDeltaFromZeroYieldsWholeGallery covers cold-start: polling from
// sequence zero returns every currently visible photo as a normal
// (non-tombstone) item, so a mirror can build its entire local copy from the
// feed alone with no separate listing call.
func TestDeltaFromZeroYieldsWholeGallery(t *testing.T) {
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

	createPhoto(t, nc, db, dir, "physical-photos", "/mounted/photos/holidays/a.jpg")
	createPhoto(t, nc, db, dir, "physical-photos", "/mounted/photos/holidays/b.jpg")
	createPhoto(t, nc, db, dir, "physical-photos", "/mounted/photos/holidays/c.jpg")

	items, nextSince := deltaAll(t, nc, "pino", 0)

	paths := make(map[string]bool)
	for _, it := range items {
		assert.False(t, it.Tombstone)
		assert.Equal(t, "photos", it.ProviderId)
		paths[it.Path] = true
	}
	assert.True(t, paths["/holidays/a.jpg"])
	assert.True(t, paths["/holidays/b.jpg"])
	assert.True(t, paths["/holidays/c.jpg"])
	assert.Greater(t, nextSince, int64(0))
}

// TestDeltaPollingFromLastSeenMissesNothingAndRepeatsNothing is the ticket's
// explicitly-demanded test: changes published BETWEEN two polls must all
// appear in the second poll, and nothing from the first poll must reappear.
func TestDeltaPollingFromLastSeenMissesNothingAndRepeatsNothing(t *testing.T) {
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

	createPhoto(t, nc, db, dir, "physical-photos", "/mounted/photos/holidays/first.jpg")

	firstItems, firstSince := deltaAll(t, nc, "pino", 0)
	require.Len(t, firstItems, 1)
	assert.Equal(t, "/holidays/first.jpg", firstItems[0].Path)

	// changes published BETWEEN the two polls
	createPhoto(t, nc, db, dir, "physical-photos", "/mounted/photos/holidays/second.jpg")
	createPhoto(t, nc, db, dir, "physical-photos", "/mounted/photos/holidays/third.jpg")

	secondItems, secondSince := deltaAll(t, nc, "pino", firstSince)

	seen := map[string]bool{}
	for _, it := range secondItems {
		seen[it.Path] = true
	}
	// everything published between the two polls is present
	assert.True(t, seen["/holidays/second.jpg"])
	assert.True(t, seen["/holidays/third.jpg"])
	// nothing already seen in the first poll reappears
	assert.False(t, seen["/holidays/first.jpg"])
	assert.Len(t, secondItems, 2)
	assert.Greater(t, secondSince, firstSince)

	// polling again from the new cursor with nothing changed yields nothing
	thirdItems, thirdSince := deltaAll(t, nc, "pino", secondSince)
	assert.Empty(t, thirdItems)
	assert.Equal(t, secondSince, thirdSince)
}

// TestDeltaDeliversTombstoneOnDelete covers: a deleted photo arrives as a
// tombstone rather than silently disappearing from the feed, so a mirror
// knows to remove it.
func TestDeltaDeliversTombstoneOnDelete(t *testing.T) {
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

	physicalPath := "/mounted/photos/holidays/gone.jpg"
	createPhoto(t, nc, db, dir, "physical-photos", physicalPath)

	items, since := deltaAll(t, nc, "pino", 0)
	require.Len(t, items, 1)
	require.False(t, items[0].Tombstone)

	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventDeleted, 0, 0, "")
	waitForCondition(t, func() bool {
		p := findPhoto(t, db, "physical-photos", physicalPath)
		return p != nil && p.Deleted
	}, "deleted photo was never marked deleted")

	afterItems, _ := deltaAll(t, nc, "pino", since)
	require.Len(t, afterItems, 1)
	assert.True(t, afterItems[0].Tombstone)
	assert.Equal(t, "/holidays/gone.jpg", afterItems[0].Path)
	assert.Equal(t, "photos", afterItems[0].ProviderId)
}

// TestDeltaChangedTwiceDeliveredOnceInCurrentState is the ticket's other
// explicitly-demanded case: a photo that changes twice between two polls
// must appear exactly once in the next poll, reflecting its LATEST state -
// not once per change. This is what Seq living on the document (rather than
// an append-only change log) is for.
func TestDeltaChangedTwiceDeliveredOnceInCurrentState(t *testing.T) {
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

	physicalPath := "/mounted/photos/holidays/twice.jpg"
	createPhoto(t, nc, db, dir, "physical-photos", physicalPath)

	baseline, since := deltaAll(t, nc, "pino", 0)
	require.Len(t, baseline, 1)
	baselineSeq := baseline[0].Seq

	// two more live events for the SAME physical key before the next poll -
	// each with a distinct EXIF Capture Date, so the final state is
	// distinguishable from both the original and the intermediate one. Waits
	// below key off CapturedAt (and, finally, Seq) rather than Size/Mime:
	// buildJPEGWithExif's fixtures can coincidentally share the same encoded
	// byte length (same pixel dimensions, same solid-color content, same
	// EXIF-string length), so Size is not a reliable "did the update land"
	// signal here even though it is a perfectly good final-state assertion.
	capturedAtV2 := time.Date(2019, 6, 6, 0, 0, 0, 0, time.UTC).Unix()
	dataV2 := buildJPEGWithExif(t, 12, 8, "2019:06:06 00:00:00", 0)
	writeFixture(t, dir, physicalPath, dataV2)
	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventChanged, int64(len(dataV2)), time.Now().Unix(), "image/jpeg")
	waitForCondition(t, func() bool {
		p := findPhoto(t, db, "physical-photos", physicalPath)
		return p != nil && p.CapturedAt == capturedAtV2
	}, "first update never landed")

	capturedAtV3 := time.Date(2020, 7, 7, 0, 0, 0, 0, time.UTC).Unix()
	dataV3 := buildJPEGWithExif(t, 12, 8, "2020:07:07 00:00:00", 0)
	writeFixture(t, dir, physicalPath, dataV3)
	publishFileChanged(t, nc, "physical-photos", physicalPath, events.FileChangedEventChanged, int64(len(dataV3)), time.Now().Unix(), "image/jpeg")
	waitForCondition(t, func() bool {
		p := findPhoto(t, db, "physical-photos", physicalPath)
		return p != nil && p.CapturedAt == capturedAtV3 && p.Seq > baselineSeq
	}, "second update never landed")

	items, _ := deltaAll(t, nc, "pino", since)
	require.Len(t, items, 1, "a photo changed twice between polls must be delivered exactly once")
	assert.Equal(t, "/holidays/twice.jpg", items[0].Path)
	assert.Equal(t, capturedAtV3, items[0].CapturedAt, "the single delivered item must reflect the LATEST state")
}

// TestDeltaFolderAdditionSurfacesAlreadyIngestedPhotos covers: a folder added
// between polls makes its already-ingested photos appear in the delta feed,
// without the client needing to know a folder was added - it just looks like
// ordinary new items the next time it polls.
//
// "Already ingested" is simulated the same way ticket 08's own tests
// simulate it: via backfill from the (stubbed) File Index, adding and then
// removing an outer folder so the photo is in the read model but not
// currently visible to pino through any configured folder - exactly the
// state a live FileChangedEvent could never reach, since ingestion's cheap
// prefix-cache reject means an event for a physical path outside every
// configured folder is never ingested at all.
func TestDeltaFolderAdditionSurfacesAlreadyIngestedPhotos(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)
	clearPendingTombstones(t, db)

	stub := newStubFileIndex(t, nc, 0)
	stub.set("physical-photos", "/mounted/photos", withProvider("physical-photos", []events.FileIndexListEntry{
		fileEntry("/mounted/photos/holidays/preexisting.jpg", 100, time.Now().Unix(), "image/jpeg"),
	}))

	// an outer folder backfills the photo into the read model, then is
	// removed - leaving the document present but not currently visible to
	// pino (the removal's own seq-bump sweep tombstones it first)
	outer := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/",
	})
	require.Equal(t, "", outer.Error)
	waitForPhotoCount(t, db, "physical-photos", 1)

	baseline, since := deltaAll(t, nc, "pino", 0)
	require.Len(t, baseline, 1)
	require.False(t, baseline[0].Tombstone)

	removed := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationRemove,
		UserId:    "pino",
		Id:        outer.SourceFolder[0].Id.Hex(),
	})
	require.Equal(t, "", removed.Error)

	waitForCondition(t, func() bool {
		items, _ := deltaAll(t, nc, "pino", since)
		return len(items) == 1 && items[0].Tombstone
	}, "removing the outer folder never tombstoned the pre-existing photo")

	afterRemoval, since := deltaAll(t, nc, "pino", since)
	require.Len(t, afterRemoval, 1)
	since = afterRemoval[0].Seq

	// now add a DIFFERENT (narrower) folder that covers the same physical
	// file, already sitting in the read model from the first folder's
	// backfill - nothing re-ingests it, it just becomes visible again
	added := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	require.Equal(t, "", added.Error)

	// the seq bump that makes this visible runs in the background (see
	// bumpSeqForPrefix/startSeqBump) - poll until it shows up
	waitForCondition(t, func() bool {
		items, _ := deltaAll(t, nc, "pino", since)
		return len(items) == 1 && !items[0].Tombstone
	}, "the pre-existing photo never surfaced through the delta feed after its folder was added")

	after, _ := deltaAll(t, nc, "pino", since)
	require.Len(t, after, 1)
	assert.False(t, after[0].Tombstone)
	assert.Equal(t, "/holidays/preexisting.jpg", after[0].Path)
}

// TestDeltaFolderRemovalTombstonesItsPhotos covers the REMOVE side of the
// same requirement: removing a folder eventually delivers tombstones for the
// photos it used to make visible, without any live file-change event ever
// firing for them.
func TestDeltaFolderRemovalTombstonesItsPhotos(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)
	clearPendingTombstones(t, db)

	dir := startFileProvider(t, "physical-photos")

	added := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	require.Equal(t, "", added.Error)
	folderId := added.SourceFolder[0].Id

	physicalPath := "/mounted/photos/holidays/removed.jpg"
	createPhoto(t, nc, db, dir, "physical-photos", physicalPath)

	baseline, since := deltaAll(t, nc, "pino", 0)
	require.Len(t, baseline, 1)
	require.False(t, baseline[0].Tombstone)

	removed := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationRemove,
		UserId:    "pino",
		Id:        folderId.Hex(),
	})
	require.Equal(t, "", removed.Error)

	waitForCondition(t, func() bool {
		items, _ := deltaAll(t, nc, "pino", since)
		return len(items) == 1 && items[0].Tombstone
	}, "removing a folder never produced a tombstone for the photo it used to make visible")
}

// TestDeltaScopedToOwnFoldersAndRevokedAccessStopsDelivery covers: a user
// never receives another user's items through the feed, and access revoked
// since a previous poll stops delivery of items under the now-inaccessible
// folder - the same access-control guarantee the listing provides, applied
// to the feed.
func TestDeltaScopedToOwnFoldersAndRevokedAccessStopsDelivery(t *testing.T) {
	accessible := map[string][]string{
		"pino": {"photos"},
		"lino": {"vacation"},
	}
	nc, db := startGalleryProvider(t, accessible)
	clearSourceFolders(t, db)
	clearPhotos(t, db)
	clearPendingTombstones(t, db)

	dirPhotos := startFileProvider(t, "physical-photos")
	dirVacation := startFileProvider(t, "physical-vacation")

	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/",
	})
	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "lino",
		SpaceProviderId: "vacation",
		Path:            "/",
	})

	createPhoto(t, nc, db, dirPhotos, "physical-photos", "/mounted/photos/mine.jpg")
	createPhoto(t, nc, db, dirVacation, "physical-vacation", "/mounted/vacation/theirs.jpg")

	pinoItems, pinoSince := deltaAll(t, nc, "pino", 0)
	require.Len(t, pinoItems, 1)
	assert.Equal(t, "/mine.jpg", pinoItems[0].Path)

	linoItems, _ := deltaAll(t, nc, "lino", 0)
	require.Len(t, linoItems, 1)
	assert.Equal(t, "/theirs.jpg", linoItems[0].Path)

	// revoke pino's access to "photos"
	accessible["pino"] = []string{}

	// a live change happens after revocation - it must not be delivered to
	// pino, since resolving pino's folders now fails
	capturedAtV2 := time.Date(2019, 6, 6, 0, 0, 0, 0, time.UTC).Unix()
	dataV2 := buildJPEGWithExif(t, 12, 8, "2019:06:06 00:00:00", 0)
	writeFixture(t, dirPhotos, "/mounted/photos/mine.jpg", dataV2)
	publishFileChanged(t, nc, "physical-photos", "/mounted/photos/mine.jpg", events.FileChangedEventChanged, int64(len(dataV2)), time.Now().Unix(), "image/jpeg")
	waitForCondition(t, func() bool {
		p := findPhoto(t, db, "physical-photos", "/mounted/photos/mine.jpg")
		return p != nil && p.CapturedAt == capturedAtV2
	}, "the update after revocation never landed in the read model")

	afterRevoke, _ := deltaAll(t, nc, "pino", pinoSince)
	assert.Empty(t, afterRevoke, "revoked access must stop delivery through the delta feed")
}

// TestDeltaCursorSurvivesRestart covers: a cursor obtained mid-poll (HasMore
// true) can be persisted and used again after a simulated app restart - i.e.
// nothing about it depends on in-process state - and resuming from it still
// yields the remaining items exactly once.
func TestDeltaCursorSurvivesRestart(t *testing.T) {
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

	const total = 12
	for i := 0; i < total; i++ {
		createPhoto(t, nc, db, dir, "physical-photos", pathFor(i))
	}

	first := delta(t, nc, &gallery.GalleryDeltaRequest{UserId: "pino", Since: 0, PageSize: 5})
	require.Equal(t, "", first.Error)
	require.Len(t, first.Items, 5)
	require.True(t, first.HasMore)
	require.NotEmpty(t, first.NextCursor)

	// simulate a restart: nothing but the persisted (Since, Cursor) pair
	// survives - a fresh request carrying exactly those values must resume
	// cleanly with no server-side session state.
	second := delta(t, nc, &gallery.GalleryDeltaRequest{UserId: "pino", Since: 0, Cursor: first.NextCursor, PageSize: 5})
	require.Equal(t, "", second.Error)
	require.Len(t, second.Items, 5)

	seen := map[string]bool{}
	for _, it := range first.Items {
		seen[it.Path] = true
	}
	for _, it := range second.Items {
		assert.False(t, seen[it.Path], "item %s from the first page must not reappear in the second", it.Path)
		seen[it.Path] = true
	}

	// drain the rest
	cursor := second.NextCursor
	for second.HasMore {
		second = delta(t, nc, &gallery.GalleryDeltaRequest{UserId: "pino", Since: 0, Cursor: cursor, PageSize: 5})
		require.Equal(t, "", second.Error)
		for _, it := range second.Items {
			assert.False(t, seen[it.Path])
			seen[it.Path] = true
		}
		cursor = second.NextCursor
	}

	assert.Len(t, seen, total)
}

func pathFor(i int) string {
	return "/mounted/photos/holidays/" + string(rune('a'+i)) + ".jpg"
}

// TestDeltaPageBoundaryWithNothingBeyondDoesNotRegressCursor covers a
// pagination edge case none of the other cursor tests exercise: a poll's
// first page returns EXACTLY PageSize items, and those items are literally
// everything that currently exists - nothing more is waiting beyond them.
// deltaFeed cannot know that from the first page alone (filling a page forces
// HasMore=true regardless of whether the underlying scan batch was also
// short - see deltaFeed's docs), so the client is required to drain one more,
// empty, continuation page before the poll is considered done.
//
// That mandatory empty continuation page is where a real regression lived:
// its NextSince was computed from a value seeded off the ORIGINAL Since the
// client sent, not the position the continuation page actually scanned from -
// so an empty continuation page reported NextSince back at the OLD Since,
// discarding everything the first, full page had already delivered. The
// client's very next poll would then re-receive the exact same items it had
// just been given, and would keep doing so on every subsequent poll (nothing
// ever advances the cursor past this boundary otherwise). This is a
// deterministic reproduction of that bug, independent of concurrency or
// timing - TestDeltaConcurrentWritersLoseNothing could only trip over it by
// accident, when 60 concurrent writers happened to leave a poll's tail
// sitting exactly on a page boundary.
func TestDeltaPageBoundaryWithNothingBeyondDoesNotRegressCursor(t *testing.T) {
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

	const total = 3
	for i := 0; i < total; i++ {
		createPhoto(t, nc, db, dir, "physical-photos", fmt.Sprintf("/mounted/photos/holidays/b-%03d.jpg", i))
	}

	// PageSize exactly matches the number of items that exist: the first page
	// fills completely, with nothing left over for the scan to have found
	// "short" - forcing the conservative HasMore=true path even though this
	// really is everything.
	first := delta(t, nc, &gallery.GalleryDeltaRequest{UserId: "pino", Since: 0, PageSize: total})
	require.Equal(t, "", first.Error)
	require.Len(t, first.Items, total)
	require.True(t, first.HasMore, "a page that fills exactly to PageSize must not yet claim to be done")
	require.NotEmpty(t, first.NextCursor)

	// the mandatory drain page: nothing further exists, so this must come
	// back empty with HasMore false - but its NextSince must reflect
	// everything the FIRST page already delivered, not regress behind it.
	drain := delta(t, nc, &gallery.GalleryDeltaRequest{UserId: "pino", Since: 0, Cursor: first.NextCursor, PageSize: total})
	require.Equal(t, "", drain.Error)
	require.Empty(t, drain.Items)
	require.False(t, drain.HasMore)
	assert.Equal(t, first.Items[total-1].Seq, drain.NextSince,
		"an empty drain page must report NextSince at the last item already delivered on the page before it, not regress behind it")

	// polling again from the drain's NextSince must not re-deliver anything
	// already received on the first page
	again, _ := deltaAll(t, nc, "pino", drain.NextSince)
	assert.Empty(t, again, "polling from the drain's NextSince re-delivered items already received on the first page")
}

// TestSequenceMonotonicAcrossSimulatedRestart covers the ticket's strictest
// requirement: sequence values are never reused, including across a service
// restart. Simulated the same way the backfill tests simulate a restart
// (see TestBackfillRestartDoesNotDuplicate): a fresh provider/connection
// pair is started against the SAME Mongo database only after the first one
// has fully stopped, so the two never run concurrently and the second one's
// nextSequence calls are genuinely "after a restart" rather than "alongside
// another live instance."
func TestSequenceMonotonicAcrossSimulatedRestart(t *testing.T) {
	provider, nc, db := getGalleryProvider(t)
	require.NoError(t, provider.Start())
	clearSourceFolders(t, db)
	clearPhotos(t, db)
	clearPendingTombstones(t, db)

	sub, err := nc.Subscribe(spaces.SpaceResolveTopic, func(msg *nats.Msg) {
		req := spaces.SpaceResolveRequest{}
		json.Unmarshal(msg.Data, &req)
		resp := spaces.SpaceResolveResponse{}
		if req.UserId == "pino" && req.SpaceProviderId == "photos" {
			resp.ProviderId = "physical-photos"
			resp.Path = "/mounted/photos"
		}
		data, _ := json.Marshal(&resp)
		msg.Respond(data)
	})
	require.NoError(t, err)
	require.NoError(t, nc.Flush())

	dir := startFileProvider(t, "physical-photos")

	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})

	before := createPhoto(t, nc, db, dir, "physical-photos", "/mounted/photos/holidays/before-restart.jpg")
	require.Greater(t, before.Seq, int64(0))

	// simulate a full service restart: stop this provider/connection
	// completely before starting a brand new one against the same Mongo
	// database. A naive in-memory counter would reset to zero here;
	// nextSequence must not, because its durable state lives in Mongo, not
	// in this process.
	require.NoError(t, sub.Unsubscribe())
	require.NoError(t, provider.Stop())
	nc.Close()

	provider2, nc2, db2 := getGalleryProvider(t)

	// the spaces stub must be listening BEFORE Start(), since Start() itself
	// synchronously builds the initial prefix cache (refreshPrefixCache) by
	// resolving every configured folder - a resolve request arriving before
	// this subscription exists would simply go unanswered.
	sub2, err := nc2.Subscribe(spaces.SpaceResolveTopic, func(msg *nats.Msg) {
		req := spaces.SpaceResolveRequest{}
		json.Unmarshal(msg.Data, &req)
		resp := spaces.SpaceResolveResponse{}
		if req.UserId == "pino" && req.SpaceProviderId == "photos" {
			resp.ProviderId = "physical-photos"
			resp.Path = "/mounted/photos"
		}
		data, _ := json.Marshal(&resp)
		msg.Respond(data)
	})
	require.NoError(t, err)
	t.Cleanup(func() { sub2.Unsubscribe() })
	require.NoError(t, nc2.Flush())

	require.NoError(t, provider2.Start())
	t.Cleanup(func() {
		provider2.Stop()
		nc2.Close()
	})

	// the restarted provider resumes serving the SAME folder configuration
	// (persisted in Mongo) without a fresh ADD - a live event for the same
	// physical prefix must still be accepted, proving the ingestion prefix
	// cache was rebuilt from persisted config on this fresh Start(), exactly
	// as Start()'s docs describe.
	after := createPhoto(t, nc2, db2, dir, "physical-photos", "/mounted/photos/holidays/after-restart.jpg")

	assert.Greater(t, after.Seq, before.Seq, "sequence allocated after a restart must be strictly greater than one allocated before it")

	// and the delta feed reflects both, in order, with no gap the client
	// could mistake for a missed item
	items, _ := deltaAll(t, nc2, "pino", 0)
	seqs := map[string]int64{}
	for _, it := range items {
		seqs[it.Path] = it.Seq
	}
	require.Contains(t, seqs, "/holidays/before-restart.jpg")
	require.Contains(t, seqs, "/holidays/after-restart.jpg")
	assert.Less(t, seqs["/holidays/before-restart.jpg"], seqs["/holidays/after-restart.jpg"])
}

// TestDeltaConcurrentWritersLoseNothing is the race test the sequential
// cases above cannot be: many photos are ingested CONCURRENTLY (ingestion
// runs ingestParallel handlers, so several documents are genuinely mid-write
// at any instant) while a client polls the feed continuously and advances its
// cursor after every poll, exactly as a real mirror would.
//
// This is what catches the sequence-gap visibility bug. Allocation and the
// document write are two separate operations, so without the allocator's
// watermark (see sequenceAllocator in sequence.go) a poll can observe seq
// N+1, serve it, and advance the client past seq N while seq N's write is
// still in flight - that photo is then permanently absent from the mirror and
// no later poll recovers it, because the cursor has already moved beyond it.
// The assertion below is therefore specifically "every photo arrived", not
// merely "the feed returned something".
func TestDeltaConcurrentWritersLoseNothing(t *testing.T) {
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

	const total = 60
	const writers = 6

	// write every fixture up front so the concurrent phase is purely
	// publish-and-ingest, with no filesystem work skewing the interleaving
	paths := make([]string, total)
	for i := 0; i < total; i++ {
		paths[i] = fmt.Sprintf("/mounted/photos/holidays/c-%03d.jpg", i)
		writeFixture(t, dir, paths[i], buildJPEGWithExif(t, 12, 8, "2019:01:01 00:00:00", 0))
	}

	// the mirror a real client would keep: applied strictly from feed pages,
	// never read back from Mongo
	var mu sync.Mutex
	mirror := make(map[string]int) // space path -> times delivered
	tombstoned := make(map[string]bool)

	pollerDone := make(chan struct{})
	stopPolling := make(chan struct{})

	pollNc, err := nats.Connect(natsServer.ClientURL())
	require.NoError(t, err)
	t.Cleanup(func() { pollNc.Close() })

	go func() {
		defer close(pollerDone)
		since := int64(0)
		for {
			res := gallery.GalleryDeltaResponse{}
			err := messaging.Request(context.Background(), pollNc, gallery.GalleryDeltaTopic,
				messaging.Json(&gallery.GalleryDeltaRequest{UserId: "pino", Since: since, PageSize: 7}),
				messaging.Json(&res))
			if err != nil {
				return
			}

			mu.Lock()
			for _, item := range res.Items {
				if item.Tombstone {
					tombstoned[item.Path] = true
					continue
				}
				mirror[item.Path]++
			}
			mu.Unlock()

			// advance exactly as a real client does: keep paging within this
			// poll, then commit the new cursor once the poll is drained
			if res.HasMore {
				// drain remaining pages of this poll before advancing Since
				cursor := res.NextCursor
				for cursor != "" {
					page := gallery.GalleryDeltaResponse{}
					if err := messaging.Request(context.Background(), pollNc, gallery.GalleryDeltaTopic,
						messaging.Json(&gallery.GalleryDeltaRequest{UserId: "pino", Since: since, Cursor: cursor, PageSize: 7}),
						messaging.Json(&page)); err != nil {
						return
					}
					mu.Lock()
					for _, item := range page.Items {
						if item.Tombstone {
							tombstoned[item.Path] = true
							continue
						}
						mirror[item.Path]++
					}
					mu.Unlock()
					if !page.HasMore {
						since = page.NextSince
						break
					}
					cursor = page.NextCursor
				}
			} else {
				since = res.NextSince
			}

			select {
			case <-stopPolling:
				return
			default:
			}
			time.Sleep(5 * time.Millisecond)
		}
	}()

	// concurrent publishers: several goroutines pushing file-change events at
	// once, which ingestion then processes with its own parallelism on top
	var wg sync.WaitGroup
	for w := 0; w < writers; w++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			pubNc, err := nats.Connect(natsServer.ClientURL())
			if err != nil {
				return
			}
			defer pubNc.Close()
			for i := worker; i < total; i += writers {
				ev := events.FileChangedEvent{
					Event:      events.Event{ID: uuid.NewString(), Version: 1},
					FileID:     uuid.NewString(),
					ProviderID: "physical-photos",
					Change:     events.FileChangedEventCreated,
					Path:       paths[i],
					Size:       673,
					ModTime:    time.Now().Unix(),
					Mime:       "image/jpeg",
				}
				data, err := ev.Marshal()
				if err != nil {
					return
				}
				pubNc.Publish(fmt.Sprintf(events.FileChangedTopicPattern, ev.FileID), data)
			}
			pubNc.Flush()
		}(w)
	}
	wg.Wait()

	// wait until every document has actually landed in the read model, so the
	// poller has something complete to converge on
	waitForPhotoCount(t, db, "physical-photos", total)

	// let the poller keep running a little longer so it can drain everything
	// written after its last poll, then stop it
	waitForCondition(t, func() bool {
		mu.Lock()
		defer mu.Unlock()
		return len(mirror) == total
	}, "the polling mirror never received every concurrently-written photo - a sequence was served while a lower one was still unwritten")

	close(stopPolling)
	<-pollerDone

	mu.Lock()
	defer mu.Unlock()

	assert.Empty(t, tombstoned, "no photo was deleted, so no tombstone should have been delivered")
	require.Len(t, mirror, total, "every concurrently-written photo must reach the mirror exactly once")
	for i := 0; i < total; i++ {
		spacePath := fmt.Sprintf("/holidays/c-%03d.jpg", i)
		assert.Equal(t, 1, mirror[spacePath], "photo %s must be delivered exactly once, not %d times", spacePath, mirror[spacePath])
	}
}
