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

package gallery

import (
	"context"
	"errors"
	"fmt"
	"os"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/file-provider/fileprovider"
)

// THE POINT OF THIS FILE - why RESCAN is not just "run backfill again".
//
// Backfill (backfill.go) reads the File Index, which is fast and cheap but
// inherits whatever staleness the index has: a file copied onto disk (e.g.
// over SMB) that the file-indexer has not yet processed is invisible to
// backfill no matter how many times it re-runs, because it never asks the
// File Provider whether the index is still accurate.
//
// RESCAN closes that gap by driving a REAL walk of the folder's physical
// tree through the File Provider client - the same client live ingestion
// uses (see ingest.go's extractForEvent) - rather than the File Index. Every
// directory it opens and lists causes the File Provider server to publish a
// FileInfoEvent for each entry (see fileprovider.FileProviderServer's
// handleStat/handleReaddir), which is the file-indexer's normal input: it
// upserts the file-indexer's own record and, if the entry is new or its
// ModTime/Size/Mode changed since the index last saw it, publishes a
// FileChangedEvent - the exact event gallery's live ingestion consumer
// (ingest.go) already subscribes to. A photo present on disk but missing
// from the index is, by definition, "new" from the file-indexer's point of
// view, so walking it always produces the FileChangedEvent that makes it
// appear in the gallery.
//
// This is genuinely a superset of what backfill can ever discover: backfill
// can only upsert what the File Index already contains, while a rescan can
// discover what the File Index does NOT yet contain and, as a side effect of
// walking it, gets the File Index itself caught up too.
//
// rescanUpsert does not exist: unlike backfill.go, this file writes NOTHING
// directly into galleryPhotos for an unchanged file. The write path stays
// singular - ingest.go's upsertPhoto, triggered by the FileChangedEvent this
// walk causes the file-indexer to publish - so RESCAN inherits every
// property already proven about that path (upsert-on-physical-key, full
// extraction, unconditional MetadataPending healing) for free, rather than
// re-deriving them for a second write path. An already-up-to-date folder
// therefore changes nothing and produces no duplicates: every file's
// FileInfoEvent lands on file-indexer's existing (providerId, path) document,
// ModTime/Size/Mode compare equal, no FileChangedEvent is published, and nothing
// downstream ever sees this folder's rescan happened at all - exactly the
// "no-op on an up-to-date folder" the ticket asks for.
//
// See healPendingMetadata below for the one thing a walk alone does NOT
// achieve - a MetadataPending item whose bytes are untouched on disk - and
// why this file addresses it too.

// rescanParallel bounds how many Gallery Source Folder rescans run
// concurrently, mirroring backfillParallel: a rescan walks a live File
// Provider tree (Stat/Readdir round trips, one per directory, plus a
// heal pass that reads file bytes) rather than the cheap File Index, so it
// is more expensive per folder than backfill and deserves at least as
// tight a cap.
const rescanParallel = 2

// startRescan launches a genuine File Provider re-scan of one Gallery Source
// Folder in the background and returns immediately - the RESCAN request/reply
// this is called from must not block on a walk that can take an arbitrary
// amount of time over a large folder, and must never hold up gallery queries
// (they share no lock with this goroutine; the read model is only ever
// touched via the same upsert paths live ingestion already uses).
//
// started reports whether a new rescan was actually launched. false means a
// rescan for this folder is already running - see markRescanRunning - so
// triggering RESCAN twice in quick succession never runs two walks over the
// same folder concurrently: the second call is a fast, harmless no-op that
// piggybacks on the one already in flight.
func (g *GalleryProvider) startRescan(folderId primitive.ObjectID) (started bool, err error) {
	ok, err := g.markRescanRunning(g.backfillCtx, folderId)
	if err != nil {
		return false, err
	}
	if !ok {
		// already running - RESCAN triggered twice in quick succession, or a
		// resumed rescan from startup still in flight
		return false, nil
	}

	g.wg.Add(1)
	go func() {
		defer g.wg.Done()
		if !g.rescanLimiter.Begin(g.backfillCtx) {
			g.clearRescanRunning(context.Background(), folderId)
			return
		}
		defer g.rescanLimiter.End()
		g.runRescan(g.backfillCtx, folderId)
	}()

	return true, nil
}

// markRescanRunning atomically flips RescanRunning from false/absent to true
// for one folder, reporting ok=false if it was already true. This single
// conditional update - not a separate read-then-write - is what makes
// "triggering a rescan twice in quick succession does not run two scans"
// hold under real concurrency: two RESCAN requests racing each other can
// only ever have one of them observe the flip.
func (g *GalleryProvider) markRescanRunning(ctx context.Context, folderId primitive.ObjectID) (bool, error) {
	filter := bson.M{"_id": folderId, "rescanRunning": bson.M{"$ne": true}}
	update := bson.M{"$set": bson.M{"rescanRunning": true}}
	result, err := g.sourceFolders.UpdateOne(ctx, filter, update)
	if err != nil {
		return false, err
	}
	return result.MatchedCount > 0, nil
}

// clearRescanRunning flips RescanRunning back to false once a walk has
// finished (successfully or not) - this is the other half of the "user gets
// feedback that a rescan has finished" contract: the app learns this the
// same way it learns everything else about a folder, by polling LIST.
func (g *GalleryProvider) clearRescanRunning(ctx context.Context, folderId primitive.ObjectID) {
	update := bson.M{"$set": bson.M{"rescanRunning": false}}
	if _, err := g.sourceFolders.UpdateByID(ctx, folderId, update); err != nil {
		g.log.Error("failed to clear rescanRunning after rescan finished", "error", err, "folderId", folderId.Hex())
	}
}

// resumeIncompleteRescans is called once at startup, mirroring
// resumeIncompleteBackfills: any Gallery Source Folder left with
// RescanRunning=true when the service last stopped had its walk interrupted
// (there is no partial-progress cursor for a rescan - see runRescan - so
// "interrupted" and "never really finished" are the same state). Simply
// clearing the flag would silently drop the user's request; re-running the
// walk from scratch is safe (a walk causes no duplicates - see this file's
// package docs) and honours the request that was still pending.
func (g *GalleryProvider) resumeIncompleteRescans(ctx context.Context) error {
	cur, err := g.sourceFolders.Find(ctx, bson.M{"rescanRunning": true})
	if err != nil {
		return fmt.Errorf("while listing incomplete gallery source folder rescans: %w", err)
	}

	folders := make([]GallerySourceFolder, 0)
	if err := cur.All(ctx, &folders); err != nil {
		return fmt.Errorf("while listing incomplete gallery source folder rescans: %w", err)
	}

	for _, f := range folders {
		g.wg.Add(1)
		go func(folderId primitive.ObjectID) {
			defer g.wg.Done()
			if !g.rescanLimiter.Begin(g.backfillCtx) {
				g.clearRescanRunning(context.Background(), folderId)
				return
			}
			defer g.rescanLimiter.End()
			g.runRescan(g.backfillCtx, folderId)
		}(f.Id)
	}

	return nil
}

// runRescan drives one folder's genuine File Provider re-scan to completion:
// a recursive walk (walkRescan) that makes file-indexer catch up with
// reality, followed by a pass that heals any MetadataPending photo left
// behind by backfill (healPendingMetadata) - see this file's package docs
// and healPendingMetadata's docs for why both steps belong to one rescan.
//
// It always clears RescanRunning on the way out, walk error or not: a rescan
// that failed partway is not retried automatically (unlike backfill, there is
// no cursor to resume from), but it must not leave the folder stuck reporting
// "running" forever - the user can simply trigger RESCAN again.
func (g *GalleryProvider) runRescan(ctx context.Context, folderId primitive.ObjectID) {
	defer g.clearRescanRunning(context.Background(), folderId)

	folder, err := g.loadSourceFolder(ctx, folderId)
	if err != nil {
		g.log.Error("failed to load gallery source folder for rescan; giving up", "error", err, "folderId", folderId.Hex())
		return
	}
	if folder == nil {
		// removed since RESCAN was requested: nothing to do
		return
	}

	p, ok := g.resolveFolderPrefix(ctx, *folder)
	if !ok {
		// resolveFolderPrefix already logged why
		return
	}

	if err := g.walkRescan(ctx, p); err != nil {
		g.log.Error("rescan: walk failed; the folder may still be stale", "error", err, "providerId", p.providerId, "path", p.path)
		// still attempt the metadata heal below - a walk failure (e.g. one
		// unreadable subdirectory) does not mean nothing on disk changed, and
		// healing is independent of how far the walk got
	} else {
		g.log.Debug("rescan: walk complete", "providerId", p.providerId, "path", p.path)
	}

	if err := g.healPendingMetadata(ctx, p); err != nil {
		g.log.Error("rescan: healing MetadataPending photos failed", "error", err, "providerId", p.providerId, "path", p.path)
	}
}

// walkRescan recursively lists p's physical directory tree through the File
// Provider client - opening each directory and calling Readdir(-1) on it,
// exactly like a WebDAV directory listing would. Every entry that comes back
// causes the File Provider server to publish a FileInfoEvent for it (see
// fileprovider.FileProviderServer's readdir handling), which is what makes
// this a REAL re-scan rather than a re-read of the File Index: the
// file-indexer receives these events exactly as if a user (or another
// client) had just browsed the folder, and reacts by publishing a
// FileChangedEvent for anything new or changed - which gallery's existing
// live ingestion consumer (ingest.go) already handles without this file
// needing to touch galleryPhotos directly.
//
// Readdir(-1) - the FULL listing - is load-bearing, not just convenient.
// The File Provider only tags a FileInfoEvent with a `readdir` marker when
// the call listed an entire directory (see handleReaddir's req.Count check),
// and that marker is what lets file-indexer reconcile DISAPPEARANCES: on a
// complete readdir it deletes every indexed child not present in the listing
// and publishes a FileChangedEvent `deleted` for each (see
// handleReaddirComplete), which gallery's live consumer turns into a
// tombstone. So a rescan corrects the index in both directions - files that
// appeared without an event and files that vanished without one. Switching
// this to a paged/partial readdir would silently drop that half.
//
// This walks breadth-first-ish but really just depth-first via recursion;
// order does not matter, because every entry is independent and idempotent
// downstream. Concurrency is deliberately NOT fanned out across
// subdirectories here (unlike ingestParallel/rescanParallel, which bound
// concurrency ACROSS folders): one rescan is already a background job that
// must not starve live ingestion and query serving of the same NATS
// connection and File Provider server, so it walks its own tree serially.
// rescanParallel is what keeps several folders' rescans from compounding
// that cost.
func (g *GalleryProvider) walkRescan(ctx context.Context, p prefix) error {
	client := fileprovider.NewFileProviderClient(p.providerId, g.nc, g.logging)
	defer client.Close()

	return g.walkDir(ctx, client, p.path)
}

// walkDir lists one directory's immediate children and recurses into every
// child that is itself a directory. See walkRescan's docs for why simply
// opening/listing is enough to make file-indexer catch up - this function's
// only job is to visit every directory under the root exactly once.
func (g *GalleryProvider) walkDir(ctx context.Context, client fileprovider.Client, dirPath string) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}

	f, err := client.OpenFile(ctx, dirPath, os.O_RDONLY, 0)
	if err != nil {
		return fmt.Errorf("opening %s: %w", dirPath, err)
	}
	defer f.Close()

	entries, err := f.Readdir(-1)
	if err != nil {
		return fmt.Errorf("listing %s: %w", dirPath, err)
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		childPath := joinPhysicalPath(dirPath, entry.Name())
		if err := g.walkDir(ctx, client, childPath); err != nil {
			// one unreadable/vanished subdirectory must not abort the rest of
			// the walk - log and keep going, exactly like backfill treats a
			// single upsert failure as non-fatal to the rest of its pass
			g.log.Error("rescan: failed to walk subdirectory; continuing with the rest of the tree", "error", err, "path", childPath)
			continue
		}
	}

	return nil
}

// healPendingMetadata is this ticket's answer to the gap ticket 08 left
// open: a folder added once and never touched again can carry
// MetadataPending photos (rung-two Capture Date, zero dimensions - see
// backfill.go's package docs) indefinitely, because nothing ever re-reads
// their bytes. walkRescan alone does NOT fix this for a file whose bytes are
// untouched on disk: file-indexer only publishes a FileChangedEvent when a
// file is new or its ModTime/Size/Mode changed (see
// fileindexer/consumer.go's upsertFile), so an unchanged MetadataPending
// file produces no event for upsertPhoto to heal it with.
//
// This closes that gap directly: for every galleryPhotos document still
// flagged MetadataPending under p's prefix, it builds the same
// FileChangedEvent shape upsertPhoto expects and runs it through upsertPhoto
// itself - the exact live-ingestion extraction path (real EXIF, real
// dimensions, unconditional MetadataPending=false) - rather than
// reimplementing extraction here. This is deliberately piggybacked on
// RESCAN rather than running on its own schedule: a rescan already pays the
// cost of contacting this folder's File Provider, RESCAN is already a
// deliberately-triggered, backgrounded, rate-limited operation (rescanLimiter),
// and healing pending metadata is exactly the kind of "make this folder
// fully up to date" work a user reaching for "Rescan folder" would expect.
//
// A photo whose extraction fails (e.g. the file has since been deleted from
// disk, or a transient File Provider error) is logged and skipped rather
// than aborting the rest of the heal pass, matching backfillUpsert's
// per-entry error handling.
func (g *GalleryProvider) healPendingMetadata(ctx context.Context, p prefix) error {
	filter := prefixFilter(p)
	filter["metadataPending"] = true
	// Tombstoned photos are deliberately excluded. markDeleted (ingest.go)
	// sets deleted:true but leaves metadataPending alone, so a backfilled
	// placeholder whose file was later deleted stays (deleted:true,
	// metadataPending:true) forever - it would otherwise be picked up here
	// and run through upsertPhoto, which unconditionally writes
	// deleted:false. That is the same "stale data resurrects a live-deleted
	// file" defect ticket 08's rework fixed in backfillUpsert by moving
	// deleted into $setOnInsert, and it must not be reintroduced through a
	// second door. Healing is for photos that are still present; a deleted
	// one has no metadata worth curing.
	filter["deleted"] = bson.M{"$ne": true}

	cur, err := g.photos.Find(ctx, filter)
	if err != nil {
		return fmt.Errorf("finding MetadataPending photos under %s/%s: %w", p.providerId, p.path, err)
	}
	defer cur.Close(ctx)

	var pending []GalleryPhoto
	if err := cur.All(ctx, &pending); err != nil {
		return fmt.Errorf("finding MetadataPending photos under %s/%s: %w", p.providerId, p.path, err)
	}

	healed, errored := 0, 0
	for _, photo := range pending {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		// ModTime is only carried through when the pending placeholder's
		// CapturedAt actually came from rung two (the file's real
		// modification time, per backfillCaptureDate) - not when it fell all
		// the way to CaptureDateSourceIndexed ("time first indexed"), which
		// is not a modification time at all and would otherwise masquerade
		// as one to resolveCaptureDate's own rung two. Leaving it zero in
		// that case correctly lets the fallback chain re-derive the same
		// "indexed" rung fresh if EXIF still yields nothing, rather than
		// feeding it a value that was never a real modification time.
		var modTime int64
		if photo.CapturedAtSource == CaptureDateSourceModTime {
			modTime = photo.CapturedAt
		}

		ev := &events.FileChangedEvent{
			ProviderID: photo.ProviderId,
			Path:       photo.Path,
			Change:     events.FileChangedEventChanged,
			Size:       photo.Size,
			ModTime:    modTime,
			Mime:       photo.Mime,
		}

		if err := g.upsertPhoto(ctx, ev); err != nil {
			errored++
			g.log.Error("rescan: failed to heal MetadataPending photo; leaving it pending",
				"error", err, "providerId", photo.ProviderId, "path", photo.Path)
			continue
		}
		healed++
	}

	g.log.Info("gallery: metadata heal pass complete",
		"providerId", p.providerId, "path", p.path,
		"pending", len(pending), "healed", healed, "errored", errored)

	return nil
}

// loadSourceFolderForUser fetches one gallerySourceFolders document by id,
// scoped to userId exactly like removeSourceFolder's filter - so a user can
// no more rescan another user's folder by guessing its id than they can
// remove one.
func (g *GalleryProvider) loadSourceFolderForUser(ctx context.Context, id primitive.ObjectID, userId string) (*GallerySourceFolder, error) {
	var folder GallerySourceFolder
	err := g.sourceFolders.FindOne(ctx, bson.M{"_id": id, "userId": userId}).Decode(&folder)
	if errors.Is(err, mongo.ErrNoDocuments) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &folder, nil
}

// rescanSourceFolder handles the RESCAN operation: it looks up the folder
// (scoped to the requesting user, like every other CRUD operation), starts
// the background walk+heal (or discovers one is already running), and
// returns immediately - the request/reply itself never waits on the walk,
// for the same reason ADD's backfill hand-off does not (see
// addSourceFolder's docs): a folder can be arbitrarily large, and this is a
// synchronous NATS request a caller is blocked on.
//
// The response's SourceFolder carries the folder as it stood at the moment
// RESCAN was accepted (RescanRunning already reflects whether this call or an
// already-in-flight one owns the walk) - the app is expected to poll LIST
// afterwards to learn when RescanRunning flips back to false, exactly as it
// already polls LIST to react to ADD/REMOVE.
func (g *GalleryProvider) rescanSourceFolder(ctx context.Context, req *GallerySourceFolderCrudRequest) *GallerySourceFolderCrudResponse {
	if req.Id == "" {
		return &GallerySourceFolderCrudResponse{
			Error: "id is required for RESCAN operation",
		}
	}

	id, err := primitive.ObjectIDFromHex(req.Id)
	if err != nil {
		return &GallerySourceFolderCrudResponse{
			Error: fmt.Errorf("invalid id: %w", err).Error(),
		}
	}

	folder, err := g.loadSourceFolderForUser(ctx, id, req.UserId)
	if err != nil {
		return &GallerySourceFolderCrudResponse{
			Error: err.Error(),
		}
	}
	if folder == nil {
		return &GallerySourceFolderCrudResponse{
			Error: "no such gallery source folder: " + req.Id,
		}
	}

	started, err := g.startRescan(folder.Id)
	if err != nil {
		return &GallerySourceFolderCrudResponse{
			Error: err.Error(),
		}
	}
	if started {
		folder.RescanRunning = true
	}
	// if !started, a rescan is already running for this folder - folder's
	// RescanRunning is already true (that is precisely how startRescan
	// decided not to start a second one), so the response already reflects
	// reality either way.

	return &GallerySourceFolderCrudResponse{
		SourceFolder: []GallerySourceFolder{*folder},
	}
}
