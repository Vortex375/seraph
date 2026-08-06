// Copyright © 2026 Benjamin Schmitz

// This file is part of Seraph <https://github.com/Vortex375/seraph>.

// Seraph is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License
// as published by the Free Software Foundation,
// either version 3 of the License, or (at your option) any later version.

// Seraph is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.

// You should have received a copy of the GNU Affero General Public License
// along with Seraph.  If not, see <http://www.gnu.org/licenses/>.

// gallery_pipeline_e2e_test.go exercises the FULL gallery ingestion pipeline
// the phone's background backup depends on, end to end against the live
// api-gateway + spaces + file-provider-dir + file-indexer + gallery stack
// started by TestMain in webdav_e2e_test.go:
//
//  1. PUT a real (small) JPEG through the WebDAV endpoint, exactly the path
//     the app's HeadlessWebDavBackend.upload takes (the same path the verb
//     suite's PUT_phone_upload_sequence drives).
//  2. Stat the uploaded file through the file-provider client - this is what
//     the app's disambiguation loop does after every PUT, and it is what
//     makes the file-provider publish the FileInfoEvent file-indexer ingests.
//  3. Poll the file-indexer's Mongo `files` collection until the JPEG appears
//     - i.e. the FileInfoEvent flowed through JetStream and was upserted.
//  4. Poll the gallery's Mongo `galleryPhotos` collection until the JPEG
//     appears - i.e. file-indexer published a FileChangedEvent AND the gallery
//     ingest consumer matched it against a Gallery Source Folder prefix and
//     upserted it.
//  5. Poll the gallery delta feed via GET /api/gallery/delta and assert the
//     JPEG is served with the expected identity and non-tombstone state -
//     i.e. what a phone polls to flip a photo's local origin from 'device'
//     to 'both' (ADR 0002's Verified gate), and what another device polls
//     to see the photo at all.
//
// This is the exact pipeline the user's "4000 photos backed up but gallery
// stuck on 'uploading'" report traced through: the WebDAV PUT succeeds, the
// files land on disk and in the file-index, but the gallery read model (and
// therefore the delta feed) never sees them, so the phone's verification
// gate never closes. A regression at any layer - file-provider not publishing
// FileInfoEvents on stat, file-indexer consumer stalled, FileChangedEvent
// not published, gallery prefix-cache dropping the event, upsertPhoto
// failing - surfaces here as a poll timeout with a concrete last-known
// state, rather than only as a phone showing a spinning cloud icon.
package e2e

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.mongodb.org/mongo-driver/bson"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"
)

// minJpeg is a minimal but valid JPEG (SOI + JFIF APP0 + tiny EOI) so the
// gallery's extractForEvent and the file-indexer's mime detection both
// recognise it as image/jpeg without needing a real image asset on disk.
// The phone uploads real camera output; this stands in for it.
var minJpeg = []byte{
	0xFF, 0xD8, 0xFF, 0xE0, // SOI + APP0 marker
	0x00, 0x10, // length 16
	'J', 'F', 'I', 'F', 0x00, // JFIF\0
	0x01, 0x01, // version 1.1
	0x00,       // density units: none
	0x00, 0x01, // X density
	0x00, 0x01, // Y density
	0x00, 0x00, // thumb w/h
	0xFF, 0xD9, // EOI
}

// galleryFolder is the in-Space sub-folder the test configures as a Gallery
// Source Folder. Matches the path shape the phone's Sync Pair uploads into:
// /Benni/Photos/Pixel 6 - a real user folder, not a test-only root, so the
// test exercises the multi-segment prefix matching the prefix cache does.
const galleryFolder = "/Benni/Photos/Pixel 6"

// galleryPipelineTimeout bounds each poll loop. Generous because the
// pipeline is async across three services on a testcontainer Mongo plus an
// embedded NATS, but not so long that a stalled pipeline wastes the whole
// run - a break here should point at the layer that stopped advancing.
const galleryPipelineTimeout = 60 * time.Second

// TestE2EGalleryPipelineLiveEvent drives the gallery pipeline via the LIVE
// event path: add the Gallery Source Folder FIRST (so backfill finds an empty
// file-index and the prefix cache covers the folder), then PUT + stat the
// JPEG. The photo must reach galleryPhotos through the FileChangedEvent the
// file-indexer publishes - the same path the phone's post-PUT disambiguation
// stat triggers. This is the user's exact scenario.
func TestE2EGalleryPipelineLiveEvent(t *testing.T) {
	runGalleryPipelineTest(t, "live-event", func(t *testing.T, relPath string) {
		// 1. Configure the folder as a Gallery Source Folder BEFORE uploading,
		//    so the prefix cache matches the FileChangedEvent the upload
		//    triggers. Backfill runs against an empty file-index and completes
		//    immediately; the live event is what carries the photo into the
		//    read model.
		addGallerySourceFolder(t, galleryFolder)

		// 2. PUT the JPEG through the WebDAV endpoint (the path the phone's
		//    HeadlessWebDavBackend takes), then stat it through the
		//    file-provider client (the path the phone's disambiguation loop
		//    takes after every PUT) so the file-provider publishes the
		//    FileInfoEvent file-indexer ingests.
		uploadAndStat(t, relPath, minJpeg)
	})
}

// TestE2EGalleryPipelineBackfill drives the gallery pipeline via the BACKFILL
// path: PUT + stat the JPEG FIRST (so the file-index has it), THEN add the
// Gallery Source Folder. Backfill queries the file-index and inserts the
// photo as a metadataPending placeholder. This is the path a freshly-added
// folder takes for already-uploaded photos, and it is the path the user's
// 215 photos came through.
func TestE2EGalleryPipelineBackfill(t *testing.T) {
	runGalleryPipelineTest(t, "backfill", func(t *testing.T, relPath string) {
		uploadAndStat(t, relPath, minJpeg)

		// Wait for the file-indexer to have the photo before adding the
		// folder, so backfill has something to find.
		requireEventualFileIndexRow(t, relPath)

		addGallerySourceFolder(t, galleryFolder)
	})
}

// runGalleryPipelineTest runs the shared arrange/act/assert shape both paths
// share. arrange varies (when the folder is added relative to the upload);
// the assertions - photo in file-index, photo in gallery, photo in delta
// feed - are identical because both paths must converge on the same read
// model state.
func runGalleryPipelineTest(t *testing.T, name string, arrange func(t *testing.T, relPath string)) {
	t.Helper()

	relPath := galleryFolder + "/PXL_" + name + ".jpg"

	// Reset the specific file + any gallery state for it from a prior run, so
	// each variant starts clean without tearing down the whole stack.
	cleanupGalleryPipelineState(t, relPath)

	arrange(t, relPath)

	// 3. The file reaches the file-indexer's Mongo `files` collection.
	requireEventualFileIndexRow(t, relPath)

	// 4. The photo reaches the gallery's Mongo `galleryPhotos` collection.
	photo := requireEventualGalleryPhoto(t, relPath)
	assert.Equal(t, providerId, photo["providerId"], "gallery providerId should be the physical file-provider id")
	assert.Equal(t, relPath, photo["path"], "gallery path should be the physical path")
	assert.False(t, photo["deleted"].(bool), "photo must not be marked deleted")
	t.Logf("gallery photo: metadataPending=%v size=%v capturedAt=%v",
		photo["metadataPending"], photo["size"], photo["capturedAt"])

	// 5. The delta feed serves the photo. This is what the phone polls to
	//    flip origin device->both (Verified), and what another device polls
	//    to see the photo at all. Poll until the photo appears - the gallery
	//    allocates a seq for the upsert asynchronously, and the delta feed
	//    scans by seq.
	deltaItem := requireEventualDeltaItem(t, relPath)
	assert.Equal(t, spaceProviderId, deltaItem.ProviderId, "delta providerId should be the space providerId")
	assert.Equal(t, relPath, deltaItem.Path, "delta path should be the space path")
	assert.False(t, deltaItem.Tombstone, "delta item must not be a tombstone for a present photo")
	assert.Equal(t, photo["size"], deltaItem.Size, "delta size should match galleryPhotos size")
	t.Logf("delta item: seq=%v capturedAt=%v metadataPending=%v",
		deltaItem.Seq, deltaItem.CapturedAt, deltaItem.MetadataPending)
}

// uploadAndStat PUTs the bytes to the WebDAV path (the atomic-PUT decorator
// creates intermediate dirs server-side, as PUT_into_missing_dir proves) and
// then stats the resulting file through the file-provider client - the
// phone's disambiguation Stat is what makes the file-provider publish the
// FileInfoEvent file-indexer ingests.
func uploadAndStat(t *testing.T, relPath string, content []byte) {
	t.Helper()
	davPath := "/dav/p/storage" + relPath

	// OPTIONS preflight (webdav_client.wdOptions before every write).
	optResp := do(t, http.MethodOptions, davPath, nil)
	if optResp.StatusCode != http.StatusOK {
		t.Fatalf("OPTIONS preflight %s: want 200, got %d (body=%s)", davPath, optResp.StatusCode, getBody(t, optResp))
	}

	// PUT the file - the atomic-PUT decorator creates missing parent dirs
	// server-side (see PUT_into_missing_dir in the verb suite), so no MKCOL
	// is needed first. This is the same path the phone takes when it PUTs
	// straight to /storage/Benni/Photos/Pixel 6/file.
	resp := putFile(t, davPath, content)
	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusNoContent {
		t.Fatalf("PUT %s: want 201/204, got %d (body=%s)", davPath, resp.StatusCode, getBody(t, resp))
	}

	// Verify it landed on disk.
	disk, err := os.ReadFile(filepath.Join(providerDir, filepath.FromSlash(relPath)))
	require.NoError(t, err, "uploaded file must exist on disk under providerDir")
	assert.Equal(t, content, disk, "disk contents must match uploaded bytes")

	// Stat through the file-provider client - this is the load-bearing step
	// for the pipeline: the file-provider server publishes a FileInfoEvent
	// for every Stat (server.go handleStat -> publishFileInfoEvent), which
	// JetStream captures into SERAPH_FILE_INFO and file-indexer consumes.
	statClient := fileprovider.NewFileProviderClient(providerId, fpConn, logging.New(logging.Params{}))
	defer statClient.Close()
	info, err := statClient.Stat(context.Background(), relPath)
	require.NoError(t, err, "stat through file-provider client must succeed")
	assert.Equal(t, int64(len(content)), info.Size(), "stat size must match uploaded size")
}

// addGallerySourceFolder configures the in-Space sub-folder as a Gallery
// Source Folder via the gateway's POST /api/gallery/source-folders, exactly
// as the app's folder picker does. The spaceProviderId ("storage") matches
// the seeded space, so the gallery service's access check + resolve pass.
func addGallerySourceFolder(t *testing.T, folderPath string) {
	t.Helper()
	body := map[string]any{
		"spaceProviderId": spaceProviderId,
		"path":            folderPath,
	}
	b, _ := json.Marshal(body)
	resp := do(t, http.MethodPost, "/api/gallery/source-folders", bytes.NewReader(b), "Content-Type", "application/json")
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("add gallery source folder %s: want 201, got %d (body=%s)", folderPath, resp.StatusCode, getBody(t, resp))
	}
}

// requireEventualFileIndexRow polls the file-indexer's Mongo `files` collection
// until a row for relPath appears, returning it. Fails the test with the
// last-seen state if the row never appears within galleryPipelineTimeout -
// which localises a break to "file-provider did not publish a FileInfoEvent"
// or "file-indexer consumer stalled", rather than letting a later, vaguer
// assertion fail.
func requireEventualFileIndexRow(t *testing.T, relPath string) bson.M {
	t.Helper()
	deadline := time.Now().Add(galleryPipelineTimeout)
	lastErr := error(nil)
	for time.Now().Before(deadline) {
		row := mongoClient.Database(fileIndexDbName).Collection("files").
			FindOne(context.Background(), bson.M{"providerId": providerId, "path": relPath})
		var doc bson.M
		err := row.Decode(&doc)
		if err == nil {
			t.Logf("file-index has %s (size=%v, pending=%v, mime=%v)",
				relPath, doc["size"], doc["pending"], doc["mime"])
			return doc
		}
		lastErr = err
		time.Sleep(500 * time.Millisecond)
	}
	t.Fatalf("file-indexer never produced a row for %s within %s (last FindOne err=%v)",
		relPath, galleryPipelineTimeout, lastErr)
	return nil
}

// requireEventualGalleryPhoto polls the gallery's Mongo `galleryPhotos`
// collection until a non-deleted row for relPath appears, returning it. The
// providerId stored is the physical providerId (providerId const), not the
// spaceProviderId - upsertPhoto writes ev.ProviderID straight through. A
// timeout here means the FileChangedEvent was not published, not matched by
// the prefix cache, or upsertPhoto errored - each of which the gallery logs
// (set SERAPH_LOG_LEVEL=debug to see them).
func requireEventualGalleryPhoto(t *testing.T, relPath string) bson.M {
	t.Helper()
	deadline := time.Now().Add(galleryPipelineTimeout)
	for time.Now().Before(deadline) {
		row := mongoClient.Database(galleryDbName).Collection("galleryPhotos").
			FindOne(context.Background(), bson.M{"providerId": providerId, "path": relPath})
		var doc bson.M
		if err := row.Decode(&doc); err == nil {
			if deleted, _ := doc["deleted"].(bool); !deleted {
				return doc
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Fatalf("gallery never produced a galleryPhotos row for %s within %s",
		relPath, galleryPipelineTimeout)
	return nil
}

// requireEventualDeltaItem polls GET /api/gallery/delta from since=0 until a
// non-tombstone item for relPath appears. This is the exact request the
// phone's GallerySyncService.sync() makes, so a pass here means the phone
// would flip origin device->both (Verified) and another device would see the
// photo. A timeout means the photo reached galleryPhotos but never got a seq
// allocated / never became visible to the delta scan - the last gap that
// would leave a photo "uploaded but not backed up".
func requireEventualDeltaItem(t *testing.T, relPath string) galleryDeltaItem {
	t.Helper()
	deadline := time.Now().Add(galleryPipelineTimeout)
	var since int64
	for time.Now().Before(deadline) {
		resp, err := http.Get(gatewayBase + "/api/gallery/delta?since=" + fmtInt(since))
		require.NoError(t, err)
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("delta feed: want 200, got %d (body=%s)", resp.StatusCode, body)
		}
		var page struct {
			Items     []galleryDeltaItem `json:"items"`
			NextCursor string             `json:"nextCursor"`
			HasMore    bool               `json:"hasMore"`
			NextSince  int64              `json:"nextSince"`
		}
		require.NoError(t, json.Unmarshal(body, &page))

		for _, it := range page.Items {
			if it.ProviderId == spaceProviderId && it.Path == relPath && !it.Tombstone {
				return it
			}
			if it.Seq > since {
				since = it.Seq
			}
		}

		// walk every page of this poll before sleeping, exactly as the
		// phone's GallerySyncService.sync() does.
		cursor := page.NextCursor
		for page.HasMore {
			resp, err := http.Get(gatewayBase + "/api/gallery/delta?since=" + fmtInt(since) + "&cursor=" + cursor)
			require.NoError(t, err)
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			require.NoError(t, json.Unmarshal(body, &page))
			for _, it := range page.Items {
				if it.ProviderId == spaceProviderId && it.Path == relPath && !it.Tombstone {
					return it
				}
				if it.Seq > since {
					since = it.Seq
				}
			}
			cursor = page.NextCursor
		}

		if page.NextSince > since {
			since = page.NextSince
		}
		time.Sleep(500 * time.Millisecond)
	}
	t.Fatalf("delta feed never served %s within %s", relPath, galleryPipelineTimeout)
	return galleryDeltaItem{}
}

// galleryDeltaItem mirrors the GalleryDeltaItem JSON the gateway returns, so
// the test can assert on the fields the phone's applyPage actually reads
// (ProviderId, Path, Seq, Tombstone, Size).
type galleryDeltaItem struct {
	ProviderId      string `json:"providerId"`
	Path            string `json:"path"`
	Seq             int64  `json:"seq"`
	Tombstone       bool   `json:"tombstone"`
	Size            int64  `json:"size"`
	CapturedAt      int64  `json:"capturedAt"`
	MetadataPending bool   `json:"metadataPending"`
}

// cleanupGalleryPipelineState removes the on-disk file, the file-index row,
// the galleryPhotos row and any gallerySourceFolder for the path, so each
// test variant starts from a clean slate without restarting the stack. The
// gallery service's upsert is idempotent on (providerId, path), so leftover
// state from a prior run would mask a regression in the live path by serving
// a stale row.
func cleanupGalleryPipelineState(t *testing.T, relPath string) {
	t.Helper()
	ctx := context.Background()

	// on-disk file under providerDir
	_ = os.Remove(filepath.Join(providerDir, filepath.FromSlash(relPath)))

	// file-index row
	_, _ = mongoClient.Database(fileIndexDbName).Collection("files").
		DeleteOne(ctx, bson.M{"providerId": providerId, "path": relPath})

	// galleryPhotos row
	_, _ = mongoClient.Database(galleryDbName).Collection("galleryPhotos").
		DeleteOne(ctx, bson.M{"providerId": providerId, "path": relPath})

	// any gallery source folder for this path - so the live-event variant's
	// "add folder first" does not collide with the backfill variant's "add
	// folder after", and so BackfillDone from a prior run does not suppress
	// a fresh backfill.
	_, _ = mongoClient.Database(galleryDbName).Collection("gallerySourceFolders").
		DeleteOne(ctx, bson.M{"spaceProviderId": spaceProviderId, "path": galleryFolder})
}

func fmtInt(n int64) string {
	return fmt.Sprintf("%d", n)
}
