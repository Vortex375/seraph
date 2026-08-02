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
	"encoding/json"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/gallery/gallery"
	"umbasa.net/seraph/spaces/spaces"
)

// stubFileProviderRecord is one fileProviders entry of a stubbed Space, as
// stored by stubSpaces.
type stubFileProviderRecord struct {
	spaceProviderId string
	providerId      string
	path            string
}

// stubSpaceRecord is one stubbed Space: its id, the users who may see it, and
// its current fileProviders. Mutating a record already registered with
// stubSpaces (through its own methods) is exactly how tests simulate an
// administrator re-pointing, revoking access to, or deleting a Space -
// mirroring how TestListExcludesFolderWhoseAccessWasRevoked mutates the
// plain `accessible` map in gallery_integration_test.go, generalized to also
// answer spaces.crud (which reactToSpaceChanged needs to look up
// fileProviders by Space id) and to publish real spaces.changed events.
type stubSpaceRecord struct {
	id            string
	users         []string
	fileProviders []stubFileProviderRecord
}

// stubSpaces is a stand-in for the `spaces` service on the shared embedded
// NATS server: it answers spaces.resolve and spaces.crud (READ) requests
// from its in-memory records, and publishes real spaces.changed events -
// through the same stream/subject the real `spaces` service uses - when a
// test calls update/delete. This lets spaceschanged_integration_test.go
// exercise the gallery service's actual JetStream consumer end to end,
// rather than calling its handler function directly.
type stubSpaces struct {
	t  *testing.T
	nc *nats.Conn

	mu      sync.Mutex
	records map[string]*stubSpaceRecord // by id
}

// newStubSpaces starts answering spaces.resolve/spaces.crud on nc, and is
// ready to publish spaces.changed events. The SERAPH_SPACES_CHANGED stream
// spaces.changed is published on already exists by the time this is called
// in every test below: getGalleryProvider/provider.Start() creates it (see
// startSpacesChangedConsumer in spaceschanged.go), exactly as the real
// spaces service creates it in its own New() - a plain nc.Publish to a
// subject matching an existing stream is captured durably regardless of
// which side created the stream.
func newStubSpaces(t *testing.T, nc *nats.Conn) *stubSpaces {
	t.Helper()

	s := &stubSpaces{
		t:       t,
		nc:      nc,
		records: make(map[string]*stubSpaceRecord),
	}

	resolveSub, err := nc.Subscribe(spaces.SpaceResolveTopic, s.handleResolve)
	require.NoError(t, err)
	t.Cleanup(func() { resolveSub.Unsubscribe() })

	crudSub, err := nc.Subscribe(spaces.SpaceCrudTopic, s.handleCrud)
	require.NoError(t, err)
	t.Cleanup(func() { crudSub.Unsubscribe() })

	require.NoError(t, nc.Flush())

	return s
}

func (s *stubSpaces) handleResolve(msg *nats.Msg) {
	req := spaces.SpaceResolveRequest{}
	json.Unmarshal(msg.Data, &req)

	resp := spaces.SpaceResolveResponse{}

	s.mu.Lock()
	for _, rec := range s.records {
		if !containsString(rec.users, req.UserId) {
			continue
		}
		for _, fp := range rec.fileProviders {
			if fp.spaceProviderId == req.SpaceProviderId {
				resp.ProviderId = fp.providerId
				resp.Path = fp.path
			}
		}
	}
	s.mu.Unlock()

	data, _ := json.Marshal(&resp)
	msg.Respond(data)
}

// handleCrud answers the one spaces.crud shape reactToSpaceChanged
// (spaceIsReferenced) actually sends: {"operation":"READ","space":{"id":"<hex>"}}
// - entities.Prototype's MarshalJSON (see entities/prototype.go) emits only
// fields that were Set(), using each field's lowerCamel json tag/name, so a
// SpacePrototype with only Id set marshals to exactly that shape rather than
// the {"Value":...,"Defined":...} internal representation of Definable.
func (s *stubSpaces) handleCrud(msg *nats.Msg) {
	var req struct {
		Operation string `json:"operation"`
		Space     struct {
			Id string `json:"id"`
		} `json:"space"`
	}
	json.Unmarshal(msg.Data, &req)

	resp := struct {
		Error string      `json:"error"`
		Space []stubSpace `json:"space"`
	}{}

	if req.Operation == "READ" && req.Space.Id != "" {
		s.mu.Lock()
		if rec, ok := s.records[req.Space.Id]; ok {
			resp.Space = []stubSpace{toStubSpace(rec)}
		}
		s.mu.Unlock()
	}

	data, _ := json.Marshal(&resp)
	msg.Respond(data)
}

// stubSpace mirrors the wire shape of spaces.Space closely enough for
// json.Unmarshal on the gallery side (spaceIsReferenced only reads
// FileProviders[].SpaceProviderId) to populate correctly.
type stubSpace struct {
	Id            string                  `json:"id"`
	FileProviders []stubSpaceFileProvider `json:"fileProviders"`
}

type stubSpaceFileProvider struct {
	SpaceProviderId string `json:"spaceProviderId"`
	ProviderId      string `json:"providerId"`
	Path            string `json:"path"`
}

func toStubSpace(rec *stubSpaceRecord) stubSpace {
	fps := make([]stubSpaceFileProvider, 0, len(rec.fileProviders))
	for _, fp := range rec.fileProviders {
		fps = append(fps, stubSpaceFileProvider{
			SpaceProviderId: fp.spaceProviderId,
			ProviderId:      fp.providerId,
			Path:            fp.path,
		})
	}
	return stubSpace{Id: rec.id, FileProviders: fps}
}

func containsString(ss []string, v string) bool {
	for _, s := range ss {
		if s == v {
			return true
		}
	}
	return false
}

// addSpace registers a new stubbed Space and returns its id, in the same hex
// ObjectID form events.SpaceChangedEvent.SpaceID carries in production (see
// spaces.SpacesProvider.publishSpaceChanged) - reactToSpaceChanged parses it
// with primitive.ObjectIDFromHex, so a UUID or other non-hex id would be
// silently treated as "not a real Space" rather than exercising the lookup
// path this file's tests are actually about.
//
// It does not publish spaces.changed - matching real CREATE, which the
// gallery service does not need to react to until a folder is added against
// it.
func (s *stubSpaces) addSpace(users []string, spaceProviderId, providerId, physicalPath string) string {
	s.t.Helper()
	id := primitive.NewObjectID().Hex()

	s.mu.Lock()
	s.records[id] = &stubSpaceRecord{
		id:    id,
		users: users,
		fileProviders: []stubFileProviderRecord{
			{spaceProviderId: spaceProviderId, providerId: providerId, path: physicalPath},
		},
	}
	s.mu.Unlock()

	return id
}

// rePoint changes the Space's file provider mount in place - simulating an
// administrator repointing a Space at a different physical location while
// keeping the same spaceProviderId - and publishes the spaces.changed
// "updated" event the real spaces service would publish for the same UPDATE.
func (s *stubSpaces) rePoint(spaceId, spaceProviderId, newProviderId, newPath string) {
	s.t.Helper()

	s.mu.Lock()
	rec := s.records[spaceId]
	require.NotNil(s.t, rec)
	for i := range rec.fileProviders {
		if rec.fileProviders[i].spaceProviderId == spaceProviderId {
			rec.fileProviders[i].providerId = newProviderId
			rec.fileProviders[i].path = newPath
		}
	}
	s.mu.Unlock()

	s.publishChanged(spaceId, events.SpaceChangedEventUpdated)
}

// revokeUser removes a user from the Space's users list - simulating access
// being revoked - and publishes the "updated" event.
func (s *stubSpaces) revokeUser(spaceId, userId string) {
	s.t.Helper()

	s.mu.Lock()
	rec := s.records[spaceId]
	require.NotNil(s.t, rec)
	kept := make([]string, 0, len(rec.users))
	for _, u := range rec.users {
		if u != userId {
			kept = append(kept, u)
		}
	}
	rec.users = kept
	s.mu.Unlock()

	s.publishChanged(spaceId, events.SpaceChangedEventUpdated)
}

// deleteSpace removes the Space entirely - simulating DELETE - and publishes
// the "deleted" event. After this, spaces.crud READ for spaceId returns no
// documents, exactly like the real service after FindOneAndDelete.
func (s *stubSpaces) deleteSpace(spaceId string) {
	s.t.Helper()

	s.mu.Lock()
	delete(s.records, spaceId)
	s.mu.Unlock()

	s.publishChanged(spaceId, events.SpaceChangedEventDeleted)
}

func (s *stubSpaces) publishChanged(spaceId, change string) {
	s.t.Helper()

	ev := events.SpaceChangedEvent{
		Event:   events.Event{ID: uuid.NewString(), Version: 1},
		SpaceID: spaceId,
		Change:  change,
	}
	data, err := ev.Marshal()
	require.NoError(s.t, err)

	topic := fmt.Sprintf(events.SpaceChangedTopicPattern, spaceId)
	require.NoError(s.t, s.nc.Publish(topic, data))
	require.NoError(s.t, s.nc.Flush())
}

// startGalleryProviderWithStubSpaces is like startGalleryProvider but returns
// the richer stubSpaces responder (mutable Space records, real
// spaces.changed publication) that this file's tests need instead of the
// static accessible-map stub.
func startGalleryProviderWithStubSpaces(t *testing.T) (*nats.Conn, *mongo.Database, *stubSpaces) {
	t.Helper()

	provider, nc, db := getGalleryProvider(t)

	if err := provider.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		provider.Stop()
		nc.Close()
	})

	stub := newStubSpaces(t, nc)

	return nc, db, stub
}

// TestIngestionFollowsRePointedSpace covers the ticket's mandated case: after
// a Space is re-pointed at a different File Provider (same spaceProviderId,
// new physical providerId/path) and its spaces.changed event is published,
// the gallery's ingestion prefix cache follows it - a file-change event at
// the NEW physical path is accepted (produces a read-model item), and one at
// the OLD physical path is no longer accepted.
func TestIngestionFollowsRePointedSpace(t *testing.T) {
	nc, db, stub := startGalleryProviderWithStubSpaces(t)
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	spaceId := stub.addSpace([]string{"pino"}, "photos", "physical-old", "/mounted/old")

	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	require.Equal(t, "", res.Error)

	dirOld := startFileProvider(t, "physical-old")
	dirNew := startFileProvider(t, "physical-new")

	data := buildJPEGWithExif(t, 12, 8, "2020:01:01 00:00:00", 0)

	// sanity: before re-pointing, the OLD physical path is what ingestion
	// accepts
	oldPath := "/mounted/old/holidays/before.jpg"
	writeFixture(t, dirOld, oldPath, data)
	publishFileChanged(t, nc, "physical-old", oldPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")
	waitForPhoto(t, db, "physical-old", oldPath)

	// re-point the Space at a different physical provider/path, same
	// spaceProviderId - this is what an administrator does when moving a
	// Space to a new File Provider
	stub.rePoint(spaceId, "photos", "physical-new", "/mounted/new")

	// the cache invalidation is asynchronous (a durable JetStream consumer
	// reacting to the published event), so the NEW path is polled for
	newPath := "/mounted/new/holidays/after.jpg"
	writeFixture(t, dirNew, newPath, data)

	require.Eventually(t, func() bool {
		publishFileChanged(t, nc, "physical-new", newPath, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")
		return findPhoto(t, db, "physical-new", newPath) != nil
	}, 10*time.Second, 100*time.Millisecond, "gallery did not start accepting events at the new physical path")

	// and the OLD path must now be REJECTED: a fresh file published there
	// after the re-point must not appear
	oldPathAfter := "/mounted/old/holidays/after-repoint.jpg"
	writeFixture(t, dirOld, oldPathAfter, data)
	publishFileChanged(t, nc, "physical-old", oldPathAfter, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")

	// give ingestion a moment to (wrongly) accept it if the cache were still
	// stale, then assert it did not
	time.Sleep(500 * time.Millisecond)
	assert.Nil(t, findPhoto(t, db, "physical-old", oldPathAfter),
		"gallery kept accepting events at the OLD physical path after the Space was re-pointed")
}

// TestIngestionStopsAfterAccessRevoked covers: a Space becoming inaccessible
// to a user (removed from its users list) makes the gallery stop returning
// photos from it - observed here at the listing boundary, which is the
// user-visible effect the acceptance criterion describes. (The query path
// itself already re-resolves fresh per request - see resolveFoldersForUser -
// so this also incidentally shows spaces.changed does not need to do
// anything for the query path to be correct; it is the ingestion side this
// ticket's cache invalidation is actually for.)
func TestIngestionStopsAfterAccessRevoked(t *testing.T) {
	nc, db, stub := startGalleryProviderWithStubSpaces(t)
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	spaceId := stub.addSpace([]string{"pino"}, "photos", "physical-photos", "/mounted/photos")

	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/",
	})
	require.Equal(t, "", res.Error)

	insertPhoto(t, db, "physical-photos", "/mounted/photos/pic.jpg", 1000, gallery.CaptureDateSourceExif, "")

	before := list(t, nc, &gallery.GalleryListRequest{UserId: "pino"})
	require.Len(t, before.Items, 1)

	stub.revokeUser(spaceId, "pino")

	require.Eventually(t, func() bool {
		after := list(t, nc, &gallery.GalleryListRequest{UserId: "pino"})
		return after.Error == "" && len(after.Items) == 0
	}, 10*time.Second, 100*time.Millisecond, "pino still sees photos from a Space their access to was revoked")
}

// TestDeletedSpaceLeavesFolderHarmlesslyUnresolvable covers: deleting a Space
// leaves its Gallery Source Folders unresolvable rather than breaking the
// user's whole listing - a second, unrelated, still-valid folder keeps
// working.
func TestDeletedSpaceLeavesFolderHarmlesslyUnresolvable(t *testing.T) {
	nc, db, stub := startGalleryProviderWithStubSpaces(t)
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	deletedSpaceId := stub.addSpace([]string{"pino"}, "gone", "physical-gone", "/mounted/gone")
	stub.addSpace([]string{"pino"}, "safe", "physical-safe", "/mounted/safe")

	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "gone",
		Path:            "/",
	})
	require.Equal(t, "", res.Error)

	res = crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "safe",
		Path:            "/",
	})
	require.Equal(t, "", res.Error)

	insertPhoto(t, db, "physical-gone", "/mounted/gone/pic.jpg", 1000, gallery.CaptureDateSourceExif, "")
	insertPhoto(t, db, "physical-safe", "/mounted/safe/pic.jpg", 2000, gallery.CaptureDateSourceExif, "")

	before := list(t, nc, &gallery.GalleryListRequest{UserId: "pino"})
	require.Len(t, before.Items, 2)

	stub.deleteSpace(deletedSpaceId)

	// the deleted Space's folder becomes unresolvable (drops out, exactly
	// like a revoked-access folder already does at query time - this is not
	// new query-path behaviour), but the surviving folder's photo must keep
	// appearing: one bad folder does not break the whole listing.
	require.Eventually(t, func() bool {
		after := list(t, nc, &gallery.GalleryListRequest{UserId: "pino"})
		if after.Error != "" || len(after.Items) != 1 {
			return false
		}
		return after.Items[0].Path == "/pic.jpg" && after.Items[0].ProviderId == "safe"
	}, 10*time.Second, 100*time.Millisecond, "listing did not settle to exactly the surviving folder's photo")

	// and ingestion for the deleted Space's old physical location must have
	// stopped too
	dir := startFileProvider(t, "physical-gone")
	newFile := "/mounted/gone/after-delete.jpg"
	data := buildJPEGWithExif(t, 10, 10, "2021:01:01 00:00:00", 0)
	writeFixture(t, dir, newFile, data)
	publishFileChanged(t, nc, "physical-gone", newFile, events.FileChangedEventCreated, int64(len(data)), time.Now().Unix(), "image/jpeg")

	time.Sleep(500 * time.Millisecond)
	assert.Nil(t, findPhoto(t, db, "physical-gone", newFile),
		"gallery kept ingesting events for a deleted Space's physical location")
}

// TestSpaceChangedForUnreferencedSpaceIsIgnoredCheaply covers: a
// spaces.changed event for a Space no Gallery Source Folder references must
// not cause a re-resolve of every configured folder. resolveCount observes
// every SpaceResolveRequest the gallery service issues from the point the
// counting subscriber is installed; the irrelevant event must produce zero of
// them, while a subsequent change to the REFERENCED Space (the harness
// sanity check) must produce at least one - proving the harness would have
// caught a naive "refresh on every event" implementation.
func TestSpaceChangedForUnreferencedSpaceIsIgnoredCheaply(t *testing.T) {
	nc, db, stub := startGalleryProviderWithStubSpaces(t)
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	// pino configures one folder against "photos"
	referencedId := stub.addSpace([]string{"pino"}, "photos", "physical-photos", "/mounted/photos")
	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/",
	})
	require.Equal(t, "", res.Error)

	// count resolve requests from this point on
	var resolveCount atomic.Int32
	countSub, err := nc.Subscribe(spaces.SpaceResolveTopic, func(msg *nats.Msg) {
		resolveCount.Add(1)
	})
	require.NoError(t, err)
	defer countSub.Unsubscribe()
	require.NoError(t, nc.Flush())

	// a completely unrelated Space, referenced by no folder at all, changes
	unrelatedId := stub.addSpace([]string{"lino"}, "unrelated", "physical-unrelated", "/mounted/unrelated")
	stub.publishChanged(unrelatedId, events.SpaceChangedEventUpdated)

	// give the durable consumer time to process the event if it were going
	// to react at all
	time.Sleep(500 * time.Millisecond)
	require.NoError(t, nc.Flush())

	assert.Equal(t, int32(0), resolveCount.Load(),
		"spaces.changed for a Space no folder references must not trigger any SpaceResolveRequest")

	// harness sanity check: changing the REFERENCED Space does trigger at
	// least one resolve, so the zero count above is meaningful and not an
	// artifact of the consumer never running at all
	stub.rePoint(referencedId, "photos", "physical-photos2", "/mounted/photos2")

	require.Eventually(t, func() bool {
		return resolveCount.Load() > 0
	}, 10*time.Second, 100*time.Millisecond, "changing a REFERENCED Space did not trigger any SpaceResolveRequest - the harness cannot distinguish 'ignored cheaply' from 'consumer never ran'")
}
