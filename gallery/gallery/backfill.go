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
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"umbasa.net/seraph/events"
)

// backfillParallel bounds how many Gallery Source Folders are backfilled
// concurrently. Deliberately modest, like ingestParallel: backfill competes
// with live ingestion and query serving for the same NATS connection, Mongo
// connection pool and CPU, and a configuration change (ADD) must never be
// allowed to turn into a heavyweight server job that starves the rest of the
// service - see the package docs on this file and ticket 08.
const backfillParallel = 2

// backfillAckTimeout/backfillReplyTimeout bound how long backfill waits for
// the File Index to ack and answer one page request, mirroring the
// ack-then-reply pattern api-gateway/search uses against the similarly
// shaped SearchRequest RPC.
const backfillAckTimeout = 5 * time.Second
const backfillReplyTimeout = 30 * time.Second

// THE METADATA TENSION (see ticket 08's rationale) and how this file
// resolves it:
//
// Backfill's contract is "reads the index, never the File Provider" - it
// must stay a cheap, backgroundable reaction to a configuration change, not
// a job that opens and decodes every file under a freshly-added folder. But
// the Capture Date EXIF rung and pixel dimensions/orientation (metadata.go)
// can only be produced by reading the actual file bytes through the File
// Provider - that is live ingestion's job (ingest.go's extractForEvent), not
// backfill's.
//
// Resolution: backfill upserts using only what FileIndexListEntry already
// carries - Size, ModTime, Mime - never opening the File Provider. Capture
// Date is resolved by the same fallback chain ingestion uses, but entering
// it at rung two (modification time) rather than rung one (EXIF), since
// EXIF requires the file bytes backfill deliberately does not read.
// Width/Height/Orientation are left zero and Unsupported is left empty
// (empty, not one of the UnsupportedReason* constants - those describe a
// decode that was attempted and failed, and backfill never attempts a
// decode at all). The document is flagged GalleryPhoto.MetadataPending so
// this is visible rather than silently indistinguishable from a live-
// ingested item with genuinely unknown dimensions.
//
// Consequence, stated plainly: a backfilled photo is initially WORSE than a
// live-ingested one - weaker Capture Date accuracy, no dimensions - and
// stays that way until something re-processes it. Nothing in this ticket
// re-scans a MetadataPending document proactively; it self-heals only when
// a live "created"/"changed" event lands on the same physical path
// (upsertPhoto always overwrites with full extraction, unconditionally
// clearing MetadataPending - see its docs). For a folder that is added once
// and never touched again, its backfilled photos could carry
// MetadataPending indefinitely. A later, proactive "finish what backfill
// started" pass is a natural follow-up ticket; it is out of scope here
// because it re-introduces exactly the File-Provider-reading cost this
// ticket exists to defer.
//
// Healing is strictly one-way. Backfill never writes over a document that
// already exists (see backfillUpsert - every field is $setOnInsert), so once
// a live event has upgraded an item to real EXIF, no amount of later
// backfilling - a resume, a nested folder, a re-ADD - can drag it back down.
// Without that property MetadataPending would be actively misleading: an
// item could hold a modification-time Capture Date while reporting itself
// fully extracted.
//
// This is a deliberate choice among the options the ticket raised, not a
// default: it keeps ADD instant and backfill cheap, at the stated cost of
// backfilled items being lower fidelity until a live event heals them.

// startBackfill launches (or resumes) backfill for one newly-added Gallery
// Source Folder in the background and returns immediately - the ADD
// request/reply this is called from must not block on it. folderId
// identifies the gallerySourceFolders document to record progress against;
// p is the resolved physical prefix backfill queries the File Index for.
func (g *GalleryProvider) startBackfill(folderId primitive.ObjectID, p prefix) {
	g.wg.Add(1)
	go func() {
		defer g.wg.Done()
		if !g.backfillLimiter.Begin(g.backfillCtx) {
			return
		}
		defer g.backfillLimiter.End()
		g.runBackfill(g.backfillCtx, folderId, p)
	}()
}

// resumeIncompleteBackfills is called once at startup: any Gallery Source
// Folder whose backfill had not finished (BackfillDone == false) when the
// service last stopped - whether it never started, or was interrupted mid-
// page by a restart - is resumed from its last recorded cursor, or restarted
// from the beginning if it has none. Either way this cannot produce
// duplicates: every page, resumed or not, goes through the same upsert this
// ticket demonstrates is safe under interleaving (see
// TestBackfillInterleavedWithLiveEventsProducesOneItem).
func (g *GalleryProvider) resumeIncompleteBackfills(ctx context.Context) error {
	cur, err := g.sourceFolders.Find(ctx, bson.M{"backfillDone": bson.M{"$ne": true}})
	if err != nil {
		return fmt.Errorf("while listing incomplete gallery source folder backfills: %w", err)
	}

	folders := make([]GallerySourceFolder, 0)
	if err := cur.All(ctx, &folders); err != nil {
		return fmt.Errorf("while listing incomplete gallery source folder backfills: %w", err)
	}

	for _, f := range folders {
		p, ok := g.resolveFolderPrefix(ctx, f)
		if !ok {
			continue
		}
		g.startBackfill(f.Id, p)
	}

	return nil
}

// resolveFolderPrefix resolves one Gallery Source Folder's Space coordinates
// to its current physical (providerId, path) prefix, logging and reporting
// ok=false exactly like refreshPrefixCache does for a folder that no longer
// resolves.
func (g *GalleryProvider) resolveFolderPrefix(ctx context.Context, f GallerySourceFolder) (prefix, bool) {
	req := spacesResolveRequest(f)
	res, err := g.resolveSpace(ctx, req)
	if err != nil || res.Error != "" || res.ProviderId == "" {
		g.log.Warn("gallery source folder does not resolve; skipping its backfill",
			"userId", f.UserId, "spaceProviderId", f.SpaceProviderId, "path", f.Path)
		return prefix{}, false
	}
	return prefix{providerId: res.ProviderId, path: joinPhysicalPath(res.Path, f.Path)}, true
}

// runBackfill drives the paged File Index prefix query to completion for one
// Gallery Source Folder, feeding every returned entry through the same
// read-model upsert live events use, and persisting progress after every
// page so a restart can resume rather than starting over.
//
// It never touches the File Provider - see the package docs above - and it
// runs entirely off the goroutine that started it, so it never blocks NATS
// message dispatch, query handling, or live-event ingestion.
func (g *GalleryProvider) runBackfill(ctx context.Context, folderId primitive.ObjectID, p prefix) {
	folder, err := g.loadSourceFolder(ctx, folderId)
	if err != nil {
		g.log.Error("failed to load gallery source folder for backfill; giving up", "error", err, "folderId", folderId.Hex())
		return
	}
	if folder == nil {
		// removed since backfill was scheduled: nothing to do
		return
	}
	if folder.BackfillDone {
		// Already finished by a previous run - e.g. startBackfill was called
		// again for an idempotent re-ADD of an already-backfilled folder, or
		// resumeIncompleteBackfills raced a concurrently-finishing backfill
		// at startup. Re-running would be harmless (backfillUpsert only ever
		// inserts, never overwrites), but it would pointlessly re-walk the
		// whole File Index prefix, so skip it. This is an efficiency guard
		// only - correctness under re-walking is backfillUpsert's job, not
		// this check's, because a nested folder re-walking a shared file is
		// a different document with its own BackfillDone flag.
		return
	}

	cursor := folder.BackfillCursor

	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		reply, err := g.requestFileIndexPage(ctx, p, cursor)
		if err != nil {
			g.log.Error("backfill: file index list request failed; will retry on next resume",
				"error", err, "providerId", p.providerId, "path", p.path)
			return
		}
		if reply.Error != "" {
			g.log.Error("backfill: file index returned an error; will retry on next resume",
				"error", reply.Error, "providerId", p.providerId, "path", p.path)
			return
		}

		for _, entry := range reply.Entries {
			if entry.IsDir {
				continue
			}
			if err := g.backfillUpsert(ctx, entry); err != nil {
				g.log.Error("backfill: failed to upsert entry; skipping it for this pass",
					"error", err, "providerId", entry.ProviderId, "path", entry.Path)
			}
		}

		cursor = reply.NextCursor
		done := !reply.HasMore

		if err := g.saveBackfillProgress(ctx, folderId, cursor, done); err != nil {
			g.log.Error("backfill: failed to persist progress", "error", err, "folderId", folderId.Hex())
		}

		if done {
			g.log.Debug("backfill complete", "providerId", p.providerId, "path", p.path)
			return
		}
	}
}

// loadSourceFolder fetches one gallerySourceFolders document by id, or nil
// if it no longer exists (e.g. removed while a scheduled backfill was still
// waiting on backfillLimiter).
func (g *GalleryProvider) loadSourceFolder(ctx context.Context, id primitive.ObjectID) (*GallerySourceFolder, error) {
	var folder GallerySourceFolder
	err := g.sourceFolders.FindOne(ctx, bson.M{"_id": id}).Decode(&folder)
	if errors.Is(err, mongo.ErrNoDocuments) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &folder, nil
}

// saveBackfillProgress records the cursor to resume from (and whether
// backfill has finished) against the owning gallerySourceFolders document.
func (g *GalleryProvider) saveBackfillProgress(ctx context.Context, folderId primitive.ObjectID, cursor string, done bool) error {
	update := bson.M{"$set": bson.M{
		"backfillCursor": cursor,
		"backfillDone":   done,
	}}
	_, err := g.sourceFolders.UpdateByID(ctx, folderId, update)
	return err
}

// backfillUpsert writes one File Index entry into the read model via the
// physical-key upsert, using only the fields the entry carries - no File
// Provider read. See the metadata tension docs above.
//
// Every field goes in $setOnInsert, making this strictly "insert this photo
// if the read model does not have it yet, otherwise leave it completely
// alone". That is not an incidental choice, it is the whole correctness
// argument: backfill can only ever produce the WEAKEST version of a document
// (rung-two modification-time Capture Date, zero dimensions), so it has
// nothing to contribute to a key that already exists and must never write
// over one.
//
// A plain $set here would be a silent data-loss bug rather than a
// pessimization. Both a resumed backfill and a nested folder's independent
// backfill can re-walk a key a live event already healed with real EXIF; a
// $set would drag capturedAt back to the file's modification time while
// leaving metadataPending false, so the photo would sort to its upload date
// forever with nothing flagged to reveal it - exactly the failure the
// "modification time is not an acceptable ordering key" rule exists to
// prevent, and exactly what MetadataPending is supposed to make visible.
// Neither backfill's own cursor nor the BackfillDone check can prevent this,
// since a nested folder is a different document with a different cursor, so
// the upsert itself has to. See
// TestBackfillDoesNotDowngradeALiveHealedItem, which covers both routes.
//
// "deleted" is included for the same reason: a live "deleted" event marks
// the document rather than removing it, so writing deleted:false
// unconditionally would let a stale File Index page resurrect a file the
// user has already deleted.
//
// The cost of this choice is that a still-pending document never picks up a
// changed size/mime from a later backfill pass. That is acceptable and
// self-correcting: anything that actually changes the file emits a live
// event, and the live path overwrites unconditionally (see upsertPhoto).
func (g *GalleryProvider) backfillUpsert(ctx context.Context, entry events.FileIndexListEntry) error {
	capturedAt, capturedAtSource := backfillCaptureDate(entry)

	// The sequence is allocated unconditionally, before knowing whether this
	// call will actually insert - $setOnInsert means a no-op call (the
	// physical key already exists) simply never writes this value anywhere,
	// so the allocated number is quietly skipped rather than reused. That is
	// fine: the allocator's contract is monotonic and unique, never
	// contiguous, so a gap left by a skipped allocation is invisible to the
	// delta feed. Going through withSequence still matters even for a
	// skipped one, because the feed must not serve past this allocation
	// while the upsert that might use it is still in flight - see
	// sequenceAllocator's docs.
	inserted := false
	err := g.withSequence(ctx, func(seq int64) error {
		filter := bson.M{"providerId": entry.ProviderId, "path": entry.Path}
		update := bson.M{
			"$setOnInsert": bson.M{
				"providerId":       entry.ProviderId,
				"path":             entry.Path,
				"capturedAt":       capturedAt,
				"capturedAtSource": capturedAtSource,
				"size":             entry.Size,
				"mime":             entry.Mime,
				"deleted":          false,
				"indexedAt":        time.Now().Unix(),
				"width":            0,
				"height":           0,
				"orientation":      0,
				"unsupported":      "",
				"metadataPending":  true,
				"seq":              seq,
			},
		}

		result, err := g.photos.UpdateOne(ctx, filter, update, options.Update().SetUpsert(true))
		if err != nil {
			return err
		}
		inserted = result.UpsertedCount > 0
		return nil
	})
	if err != nil {
		return err
	}

	// dispatch background Thumbnail pre-generation for a photo genuinely new
	// to the read model - fire-and-forget onto the durable warm work queue,
	// exactly like the live-ingestion path (see upsertPhoto/
	// dispatchThumbnailWarm). Skipped when this call was a no-op (the
	// physical key already existed, e.g. a resumed or nested-folder
	// backfill re-walking an already-ingested photo): that photo was either
	// already warmed when it first entered the read model, or - per the
	// metadata tension this file's package docs describe - already
	// live-healed, in which case its warm request was already dispatched by
	// upsertPhoto. Re-dispatching would be harmless (see
	// events.ThumbnailWarmRequest's docs) but is needless amplification
	// across thousands of backfilled entries with nothing to gain.
	if inserted {
		g.dispatchThumbnailWarm(ctx, entry.ProviderId, entry.Path)
	}

	return nil
}

// backfillCaptureDate implements the Capture Date fallback chain starting at
// rung two (modification time), since backfill never has file bytes to read
// EXIF from - see the metadata tension docs above.
func backfillCaptureDate(entry events.FileIndexListEntry) (int64, string) {
	if entry.ModTime != 0 {
		return entry.ModTime, CaptureDateSourceModTime
	}
	return time.Now().Unix(), CaptureDateSourceIndexed
}

// requestFileIndexPage issues one FileIndexListRequest and waits for its ack
// and reply, following the ack-then-reply convention
// events.FileIndexListRequest documents (mirrored from the existing search
// request api-gateway/search consumes).
func (g *GalleryProvider) requestFileIndexPage(ctx context.Context, p prefix, cursor string) (*events.FileIndexListReply, error) {
	requestId := uuid.NewString()

	ackChan := make(chan *nats.Msg, 1)
	replyChan := make(chan *nats.Msg, 1)

	ackSub, err := g.nc.ChanSubscribe(fmt.Sprintf(events.FileIndexListAckTopicPattern, requestId), ackChan)
	if err != nil {
		return nil, err
	}
	defer ackSub.Unsubscribe()

	replySub, err := g.nc.ChanSubscribe(fmt.Sprintf(events.FileIndexListReplyTopicPattern, requestId), replyChan)
	if err != nil {
		return nil, err
	}
	defer replySub.Unsubscribe()

	req := events.FileIndexListRequest{
		RequestId:  requestId,
		ProviderId: p.providerId,
		Path:       p.path,
		Cursor:     cursor,
	}
	data, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	if err := g.nc.Publish(events.FileIndexListRequestTopic, data); err != nil {
		return nil, err
	}

	ackTimer := time.NewTimer(backfillAckTimeout)
	defer ackTimer.Stop()

	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-ackTimer.C:
		return nil, fmt.Errorf("no ack from file index for request %s within %s", requestId, backfillAckTimeout)
	case ackMsg := <-ackChan:
		ack := events.FileIndexListAck{}
		if err := json.Unmarshal(ackMsg.Data, &ack); err != nil {
			return nil, err
		}
		if !ack.Ack {
			return nil, fmt.Errorf("file index declined request %s", requestId)
		}
	}

	replyTimer := time.NewTimer(backfillReplyTimeout)
	defer replyTimer.Stop()

	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-replyTimer.C:
		return nil, fmt.Errorf("no reply from file index for request %s within %s", requestId, backfillReplyTimeout)
	case replyMsg := <-replyChan:
		reply := events.FileIndexListReply{}
		if err := json.Unmarshal(replyMsg.Data, &reply); err != nil {
			return nil, err
		}
		return &reply, nil
	}
}
