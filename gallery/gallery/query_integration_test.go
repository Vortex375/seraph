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
	"testing"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"umbasa.net/seraph/gallery/gallery"
	"umbasa.net/seraph/messaging"
)

// insertPhoto writes a GalleryPhoto document directly into the read model,
// bypassing ingestion. The query implementation being tested here is
// downstream of ingestion (package 1), so its tests seed the read model
// directly rather than re-driving the whole ingest path for every fixture -
// exactly like the ingest tests seed the File Provider directly rather than
// going through, say, a WebDAV client.
func insertPhoto(t *testing.T, db *mongo.Database, providerId, path string, capturedAt int64, source string, unsupported string) {
	t.Helper()
	doc := bson.M{
		"providerId":       providerId,
		"path":             path,
		"capturedAt":       capturedAt,
		"capturedAtSource": source,
		"width":            10,
		"height":           20,
		"orientation":      1,
		"size":             123,
		"mime":             "image/jpeg",
		"unsupported":      unsupported,
		"deleted":          false,
		"indexedAt":        time.Now().Unix(),
	}
	_, err := db.Collection("galleryPhotos").InsertOne(context.Background(), doc)
	require.NoError(t, err)
}

func list(t *testing.T, nc *nats.Conn, req *gallery.GalleryListRequest) *gallery.GalleryListResponse {
	t.Helper()
	res := gallery.GalleryListResponse{}
	err := messaging.Request(context.Background(), nc, gallery.GalleryListTopic, messaging.Json(req), messaging.Json(&res))
	require.NoError(t, err)
	return &res
}

// TestListReturnsPhotosInCaptureDateOrder covers the core ordering
// requirement: a photo appearing in a configured folder shows up at the
// position its Capture Date implies, newest first.
func TestListReturnsPhotosInCaptureDateOrder(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})

	base := time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC).Unix()
	insertPhoto(t, db, "physical-photos", "/mounted/photos/holidays/a.jpg", base+100, gallery.CaptureDateSourceExif, "")
	insertPhoto(t, db, "physical-photos", "/mounted/photos/holidays/b.jpg", base+300, gallery.CaptureDateSourceExif, "")
	insertPhoto(t, db, "physical-photos", "/mounted/photos/holidays/c.jpg", base+200, gallery.CaptureDateSourceExif, "")

	res := list(t, nc, &gallery.GalleryListRequest{UserId: "pino"})
	assert.Equal(t, "", res.Error)
	require.Len(t, res.Items, 3)
	assert.Equal(t, "/holidays/b.jpg", res.Items[0].Path)
	assert.Equal(t, "/holidays/c.jpg", res.Items[1].Path)
	assert.Equal(t, "/holidays/a.jpg", res.Items[2].Path)
	assert.False(t, res.HasMore)
}

// TestListTranslatesToSpacePaths covers: the read model is keyed physically
// but the API returns Space paths that work directly against the existing
// preview/download endpoints (providerId = the Space provider id, path =
// folder.Path + remainder).
func TestListTranslatesToSpacePaths(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})

	// resolved physical prefix per the stub resolver in startGalleryProvider
	// is "/mounted/photos" for spaceProviderId "photos"
	insertPhoto(t, db, "physical-photos", "/mounted/photos/holidays/sub/beach.jpg", 1000, gallery.CaptureDateSourceExif, "")

	res := list(t, nc, &gallery.GalleryListRequest{UserId: "pino"})
	assert.Equal(t, "", res.Error)
	require.Len(t, res.Items, 1)
	assert.Equal(t, "photos", res.Items[0].ProviderId)
	assert.Equal(t, "/holidays/sub/beach.jpg", res.Items[0].Path)
}

// TestListIsScopedToOwnSourceFoldersOnly covers: a user sees exactly the
// union of their own Gallery Source Folders and nothing else - not another
// user's folders, and not physical files outside any of their own folders
// even if some other user's folder happens to cover them.
func TestListIsScopedToOwnSourceFoldersOnly(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
		"lino": {"vacation"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

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

	insertPhoto(t, db, "physical-photos", "/mounted/photos/mine.jpg", 1000, gallery.CaptureDateSourceExif, "")
	insertPhoto(t, db, "physical-vacation", "/mounted/vacation/theirs.jpg", 2000, gallery.CaptureDateSourceExif, "")

	pinoRes := list(t, nc, &gallery.GalleryListRequest{UserId: "pino"})
	require.Len(t, pinoRes.Items, 1)
	assert.Equal(t, "/mine.jpg", pinoRes.Items[0].Path)

	linoRes := list(t, nc, &gallery.GalleryListRequest{UserId: "lino"})
	require.Len(t, linoRes.Items, 1)
	assert.Equal(t, "/theirs.jpg", linoRes.Items[0].Path)

	// a user with no configured folders at all sees nothing
	noneRes := list(t, nc, &gallery.GalleryListRequest{UserId: "stranger"})
	assert.Equal(t, "", noneRes.Error)
	assert.Empty(t, noneRes.Items)
}

// TestListExcludesFolderWhoseAccessWasRevoked covers: access control falls
// out of resolving the user's folders at query time. A folder that no
// longer resolves for its owner (access revoked) contributes nothing to the
// listing - the photos physically underneath it simply disappear from view,
// with no separate permission check and no reverse mapping to keep in sync.
func TestListExcludesFolderWhoseAccessWasRevoked(t *testing.T) {
	accessible := map[string][]string{
		"pino": {"photos"},
	}
	nc, db := startGalleryProvider(t, accessible)
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/",
	})

	insertPhoto(t, db, "physical-photos", "/mounted/photos/pic.jpg", 1000, gallery.CaptureDateSourceExif, "")

	before := list(t, nc, &gallery.GalleryListRequest{UserId: "pino"})
	require.Len(t, before.Items, 1)

	// revoke: the stub resolver now refuses "photos" for "pino"
	accessible["pino"] = []string{}

	after := list(t, nc, &gallery.GalleryListRequest{UserId: "pino"})
	assert.Equal(t, "", after.Error)
	assert.Empty(t, after.Items)
}

// TestListIncludesUnsupportedItems covers: an item recorded with an
// "unsupported" reason still appears in the listing rather than being
// omitted - backup coverage and display are independent questions.
func TestListIncludesUnsupportedItems(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/",
	})

	insertPhoto(t, db, "physical-photos", "/mounted/photos/raw.arw", 1000, gallery.CaptureDateSourceIndexed, gallery.UnsupportedReasonFormat)

	res := list(t, nc, &gallery.GalleryListRequest{UserId: "pino"})
	require.Len(t, res.Items, 1)
	assert.Equal(t, gallery.UnsupportedReasonFormat, res.Items[0].Unsupported)
}

// TestListExcludesDeletedPhotos covers: a photo flagged deleted by a
// "deleted" file-change event does not appear in the listing.
func TestListExcludesDeletedPhotos(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/",
	})

	insertPhoto(t, db, "physical-photos", "/mounted/photos/gone.jpg", 1000, gallery.CaptureDateSourceExif, "")
	_, err := db.Collection("galleryPhotos").UpdateOne(context.Background(),
		bson.M{"providerId": "physical-photos", "path": "/mounted/photos/gone.jpg"},
		bson.M{"$set": bson.M{"deleted": true}})
	require.NoError(t, err)

	res := list(t, nc, &gallery.GalleryListRequest{UserId: "pino"})
	assert.Empty(t, res.Items)
}

// TestListPagesStablyThroughThousandsWithTies is the cursor test the ticket
// calls out explicitly: paging through a few thousand photos, including
// ties on Capture Date, must yield each item exactly once - no skips, no
// duplicates - using the keyset cursor rather than skip/limit.
func TestListPagesStablyThroughThousandsWithTies(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/",
	})

	const total = 2500
	const numDistinctDates = 50 // forces ~50 photos to share each capturedAt value
	base := time.Date(2021, 1, 1, 0, 0, 0, 0, time.UTC).Unix()

	docs := make([]any, 0, total)
	expectedPaths := make(map[string]bool, total)
	for i := 0; i < total; i++ {
		capturedAt := base + int64(i%numDistinctDates)
		p := fmt.Sprintf("/photo-%05d.jpg", i)
		expectedPaths[p] = true
		docs = append(docs, bson.M{
			"providerId":       "physical-photos",
			"path":             "/mounted/photos" + p,
			"capturedAt":       capturedAt,
			"capturedAtSource": gallery.CaptureDateSourceExif,
			"width":            1,
			"height":           1,
			"orientation":      1,
			"size":             1,
			"mime":             "image/jpeg",
			"unsupported":      "",
			"deleted":          false,
			"indexedAt":        time.Now().Unix(),
		})
	}
	_, err := db.Collection("galleryPhotos").InsertMany(context.Background(), docs)
	require.NoError(t, err)

	seen := make(map[string]int, total)
	var lastCapturedAt int64 = 1<<63 - 1
	cursor := ""
	pages := 0
	for {
		res := list(t, nc, &gallery.GalleryListRequest{UserId: "pino", PageSize: 137, Cursor: cursor})
		require.Equal(t, "", res.Error)
		pages++
		require.Less(t, pages, total, "paging did not terminate")

		for _, item := range res.Items {
			seen[item.Path]++
			// ordering must be non-increasing capturedAt across the whole
			// paged sequence, not just within a page
			require.LessOrEqual(t, item.CapturedAt, lastCapturedAt,
				"capturedAt must be non-increasing across pages at %s", item.Path)
			lastCapturedAt = item.CapturedAt
		}

		if !res.HasMore {
			assert.Empty(t, res.NextCursor)
			break
		}
		require.NotEmpty(t, res.NextCursor)
		cursor = res.NextCursor
	}

	require.Equal(t, total, len(seen), "expected every photo to have been seen")
	for p := range expectedPaths {
		assert.Equal(t, 1, seen[p], "photo %s must appear exactly once", p)
	}
}

// TestListCursorContinuesAcrossConcurrentInsert covers robustness of the
// keyset cursor: a page fetched with a cursor must not skip or duplicate
// items even if new photos are inserted between page fetches, since the
// cursor is a fixed position in (capturedAt, _id) space rather than an
// offset that shifts as the underlying set changes.
func TestListCursorContinuesAcrossConcurrentInsert(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)
	clearPhotos(t, db)

	crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/",
	})

	base := time.Date(2022, 1, 1, 0, 0, 0, 0, time.UTC).Unix()
	for i := 0; i < 10; i++ {
		insertPhoto(t, db, "physical-photos", fmt.Sprintf("/mounted/photos/old-%02d.jpg", i), base-int64(i), gallery.CaptureDateSourceExif, "")
	}

	first := list(t, nc, &gallery.GalleryListRequest{UserId: "pino", PageSize: 5})
	require.Len(t, first.Items, 5)
	require.True(t, first.HasMore)

	// a new, newer-dated photo arrives after the first page was already
	// fetched - it must not appear inserted into the already-fetched
	// sequence, and must not cause any old item to be skipped or repeated
	insertPhoto(t, db, "physical-photos", "/mounted/photos/new.jpg", base+1000, gallery.CaptureDateSourceExif, "")

	second := list(t, nc, &gallery.GalleryListRequest{UserId: "pino", PageSize: 5, Cursor: first.NextCursor})
	require.Len(t, second.Items, 5)

	seen := map[string]bool{}
	for _, item := range first.Items {
		seen[item.Path] = true
	}
	for _, item := range second.Items {
		assert.False(t, seen[item.Path], "item %s from the first page must not reappear in the second", item.Path)
		seen[item.Path] = true
	}
	// the newly inserted, newer photo must not appear in either page: both
	// pages were seeking from a fixed position that already sat below it
	assert.False(t, seen["/new.jpg"])
	assert.Len(t, seen, 10)
}
