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
	"testing"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"umbasa.net/seraph/gallery/gallery"
	"umbasa.net/seraph/spaces/spaces"
)

// clearDotfileSweepMarker removes the one-off sweep's "done" marker so a test
// can exercise the sweep against a database other tests may have already left
// marked-done. Only the marker document is deleted - the sequence counter
// document (gallerySequenceCounterId) is left untouched so seq monotonicity
// across the shared test database is preserved.
func clearDotfileSweepMarker(t *testing.T, db *mongo.Database) {
	t.Helper()
	if _, err := db.Collection("gallerySequenceCounters").DeleteOne(context.Background(), bson.M{"_id": "dotfileSweepDone"}); err != nil {
		t.Fatal(err)
	}
}

// dotfileSweepMarkerExists reports whether the one-off sweep's "done" marker
// is present, so a test can assert the sweep completed (marker set) or did
// not run (marker absent).
func dotfileSweepMarkerExists(t *testing.T, db *mongo.Database) bool {
	t.Helper()
	err := db.Collection("gallerySequenceCounters").FindOne(context.Background(), bson.M{"_id": "dotfileSweepDone"}).Decode(bson.M{})
	return err == nil
}

// insertDotfile writes a galleryPhotos document directly into the read model
// for a dotfile path (one whose final segment begins with "."), bypassing
// ingestion - which ticket 01 made reject dotfiles - so the test can simulate
// a pre-existing dotfile leak from before that filter landed. It carries no
// seq (seq=0), exactly like insertPhoto, so the sweep's markDeleted is what
// gives it its first real delta-feed sequence.
func insertDotfile(t *testing.T, db *mongo.Database, providerId, path string) {
	t.Helper()
	doc := bson.M{
		"providerId":       providerId,
		"path":             path,
		"capturedAt":       int64(0),
		"capturedAtSource": gallery.CaptureDateSourceIndexed,
		"width":            0,
		"height":           0,
		"orientation":      0,
		"size":             int64(0),
		"mime":             "",
		"unsupported":      "",
		"deleted":          false,
		"indexedAt":        int64(0),
	}
	_, err := db.Collection("galleryPhotos").InsertOne(context.Background(), doc)
	require.NoError(t, err)
}

// TestDotfileSweepTombstonesPreExistingDotfiles covers the ticket's core
// requirement: a one-off startup sweep finds every galleryPhotos document
// whose final path segment begins with "." and runs it through markDeleted,
// so the delta feed delivers its tombstone to every mirror exactly like a
// live deletion would. Non-dotfile documents are not touched.
func TestDotfileSweepTombstonesPreExistingDotfiles(t *testing.T) {
	// manual lifecycle: dotfile documents must be seeded BEFORE Start() so
	// the sweep goroutine (launched by Start()) finds them - exactly the
	// pre-existing-leak state the sweep exists to clean up.
	provider, nc, db := getGalleryProvider(t)
	clearSourceFolders(t, db)
	clearPhotos(t, db)
	clearPendingTombstones(t, db)
	clearDotfileSweepMarker(t, db)

	// seed dotfile documents directly into the read model BEFORE Start() -
	// they simulate the pre-existing leak (a .DS_Store, an interrupted-upload
	// staging file) the sweep exists to clean up. Seeded with no seq (seq=0)
	// so the sweep's markDeleted is what gives each its first real delta-feed
	// sequence, proving the seq was bumped.
	insertDotfile(t, db, "physical-photos", "/mounted/photos/holidays/.DS_Store")
	insertDotfile(t, db, "physical-photos", "/mounted/photos/holidays/.foo.jpg.part")

	// spaces stub must be listening BEFORE Start(), since Start() builds the
	// initial prefix cache by resolving every configured folder.
	stub, err := nc.Subscribe(spaces.SpaceResolveTopic, func(msg *nats.Msg) {
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

	require.NoError(t, provider.Start())
	t.Cleanup(func() {
		provider.Stop()
		nc.Close()
	})
	t.Cleanup(func() { stub.Unsubscribe() })

	// a non-dotfile photo created through the normal live-ingest path, so it
	// carries a real allocated seq and is the control the sweep must NOT
	// touch.
	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	dir := startFileProvider(t, "physical-photos")
	normal := createPhoto(t, nc, db, dir, "physical-photos", "/mounted/photos/holidays/normal.jpg")
	normalSeq := normal.Seq

	// wait for the sweep to tombstone both dotfiles
	waitForCondition(t, func() bool {
		a := findPhoto(t, db, "physical-photos", "/mounted/photos/holidays/.DS_Store")
		b := findPhoto(t, db, "physical-photos", "/mounted/photos/holidays/.foo.jpg.part")
		return a != nil && a.Deleted && a.Seq > 0 &&
			b != nil && b.Deleted && b.Seq > 0
	}, "the sweep never tombstoned the pre-existing dotfile documents")

	dotA := findPhoto(t, db, "physical-photos", "/mounted/photos/holidays/.DS_Store")
	dotB := findPhoto(t, db, "physical-photos", "/mounted/photos/holidays/.foo.jpg.part")
	assert.True(t, dotA.Deleted)
	assert.Greater(t, dotA.Seq, int64(0), "swept dotfile must have its seq bumped by markDeleted")
	assert.True(t, dotB.Deleted)
	assert.Greater(t, dotB.Seq, int64(0))

	// the non-dotfile is untouched: still not deleted, seq unchanged
	afterNormal := findPhoto(t, db, "physical-photos", "/mounted/photos/holidays/normal.jpg")
	require.NotNil(t, afterNormal)
	assert.False(t, afterNormal.Deleted)
	assert.Equal(t, normalSeq, afterNormal.Seq, "the sweep must not touch non-dotfile documents")

	// the marker is set once the sweep completes
	waitForCondition(t, func() bool {
		return dotfileSweepMarkerExists(t, db)
	}, "the sweep never set its done marker")

	// a subsequent delta poll delivers the dotfiles as tombstones through the
	// same path a live deletion would (TestDeltaDeliversTombstoneOnDelete
	// shape), and the non-dotfile as a normal item.
	items, _ := deltaAll(t, nc, "pino", 0)
	tomb := map[string]bool{}
	normalDelivered := false
	for _, it := range items {
		if it.Tombstone {
			tomb[it.Path] = true
		}
		if it.Path == "/holidays/normal.jpg" {
			normalDelivered = !it.Tombstone
		}
	}
	assert.True(t, tomb["/holidays/.DS_Store"], "swept dotfile must arrive as a tombstone")
	assert.True(t, tomb["/holidays/.foo.jpg.part"], "swept dotfile must arrive as a tombstone")
	assert.True(t, normalDelivered, "non-dotfile must still arrive as a normal item")
}

// TestDotfileSweepDoesNotReRunAfterMarkerSet covers the restart requirement:
// once the sweep has run and set its "done" marker, a subsequent start does
// NOT re-run it. Asserted by inserting a fresh dotfile after the first sweep
// completed and verifying a restart leaves it untombstoned - the marker is
// honoured, so the sweep is a no-op on the second start.
func TestDotfileSweepDoesNotReRunAfterMarkerSet(t *testing.T) {
	// manual lifecycle: this test drives two Start/Stop cycles against the
	// same Mongo database, mirroring TestSequenceMonotonicAcrossSimulatedRestart.
	provider, nc, db := getGalleryProvider(t)
	clearSourceFolders(t, db)
	clearPhotos(t, db)
	clearPendingTombstones(t, db)
	clearDotfileSweepMarker(t, db)

	// spaces stub must be listening BEFORE Start(), since Start() builds the
	// initial prefix cache by resolving every configured folder.
	stub, err := nc.Subscribe(spaces.SpaceResolveTopic, func(msg *nats.Msg) {
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

	// seed a dotfile BEFORE the first start so the first sweep has something
	// to tombstone - proving the sweep ran.
	insertDotfile(t, db, "physical-photos", "/mounted/photos/holidays/.DS_Store")

	require.NoError(t, provider.Start())

	// wait for the first sweep to tombstone the dotfile AND set the marker
	waitForCondition(t, func() bool {
		p := findPhoto(t, db, "physical-photos", "/mounted/photos/holidays/.DS_Store")
		return p != nil && p.Deleted && p.Seq > 0
	}, "the first sweep never tombstoned the pre-existing dotfile")
	waitForCondition(t, func() bool {
		return dotfileSweepMarkerExists(t, db)
	}, "the first sweep never set its done marker")

	// simulate a full restart: stop the provider completely before starting a
	// fresh one against the same Mongo database.
	require.NoError(t, stub.Unsubscribe())
	require.NoError(t, provider.Stop())
	nc.Close()

	provider2, nc2, db2 := getGalleryProvider(t)
	stub2, err := nc2.Subscribe(spaces.SpaceResolveTopic, func(msg *nats.Msg) {
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
	t.Cleanup(func() { stub2.Unsubscribe() })
	require.NoError(t, nc2.Flush())

	// insert a FRESH dotfile after the first sweep completed but BEFORE the
	// second start. If the second start re-ran the sweep, this dotfile would
	// be tombstoned; because the marker is already set, the sweep is a no-op
	// and the dotfile must remain untouched.
	insertDotfile(t, db2, "physical-photos", "/mounted/photos/holidays/.fresh_after_restart")

	require.NoError(t, provider2.Start())
	t.Cleanup(func() {
		provider2.Stop()
		nc2.Close()
	})

	// give the second sweep (if it ran) ample time to tombstone the fresh
	// dotfile - then assert it did NOT. A short settle delay is the
	// negative-assertion convention waitForCondition + sleep uses elsewhere
	// (see TestRemoveTouchesNoFileProvider).
	waitForCondition(t, func() bool {
		return dotfileSweepMarkerExists(t, db2)
	}, "marker disappeared after restart")
	time.Sleep(500 * time.Millisecond)

	fresh := findPhoto(t, db2, "physical-photos", "/mounted/photos/holidays/.fresh_after_restart")
	require.NotNil(t, fresh, "fresh dotfile was removed; the sweep must only tombstone, never delete")
	assert.False(t, fresh.Deleted, "the sweep re-ran after the marker was set, tombstoning a dotfile it should have left alone")
	assert.Equal(t, int64(0), fresh.Seq, "the sweep re-ran after the marker was set, bumping a seq it should have left alone")
}
