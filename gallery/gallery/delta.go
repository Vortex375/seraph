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
	"encoding/base64"
	"encoding/json"
	"fmt"
	"path"
	"strconv"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo/options"
)

// deltaCursor is the decoded form of a GalleryDeltaRequest.Cursor: a position
// in the (seq) keyset the delta scan is paged over, within the current poll
// (i.e. for the same Since). Like listCursor (query.go), it is opaque on the
// wire so the encoding is free to change later.
type deltaCursor struct {
	seq int64
}

func encodeDeltaCursor(seq int64) string {
	raw, _ := json.Marshal(strconv.FormatInt(seq, 10))
	return base64.RawURLEncoding.EncodeToString(raw)
}

func decodeDeltaCursor(s string) (deltaCursor, error) {
	if s == "" {
		return deltaCursor{}, nil
	}
	raw, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil {
		return deltaCursor{}, fmt.Errorf("invalid cursor: %w", err)
	}
	var part string
	if err := json.Unmarshal(raw, &part); err != nil {
		return deltaCursor{}, fmt.Errorf("invalid cursor: %w", err)
	}
	seq, err := strconv.ParseInt(part, 10, 64)
	if err != nil {
		return deltaCursor{}, fmt.Errorf("invalid cursor: %w", err)
	}
	return deltaCursor{seq: seq}, nil
}

// deltaScanBatchSize mirrors scanBatchSize (query.go): the read model is
// shared and keyed physically, so "this user's changes" cannot be pushed
// into the seq index as a filter - candidates are pulled from the
// seq-ordered index in batches and matched in memory against the user's
// resolved folders, exactly like the listing does against Capture Date
// order.
const deltaScanBatchSize = 500

// deltaSort is the delta feed's page ordering: seq ascending, so "since N"
// is a plain seek past position N with no tie-break needed - seq is already
// unique per document (see nextSequence).
var deltaSort = bson.D{{Key: "seq", Value: 1}}

// pendingTombstone is one row of galleryPendingTombstones: a folder-removal
// tombstone still owed to a specific user. See recordRemovalTombstones for
// why this exists as its own small per-user collection rather than being
// folded into galleryPhotos.
type pendingTombstone struct {
	UserId          string    `bson:"userId"`
	SpaceProviderId string    `bson:"spaceProviderId"`
	SpacePath       string    `bson:"spacePath"`
	Seq             int64     `bson:"seq"`
	CreatedAt       time.Time `bson:"createdAt"`
}

// DeltaTombstoneRetention is how long a folder-removal tombstone stays
// available in the feed before Mongo expires it, enforced by the TTL index on
// galleryPendingTombstones.createdAt (migration 000004).
//
// These rows are written per photo per user on every folder REMOVE, so
// without an expiry the collection would grow without bound - folder churn
// on a large gallery would accumulate rows forever. Consumption-based
// cleanup was rejected for exactly the failure it cannot handle: a client
// that polls once and never returns (app deleted, device lost) would pin its
// rows permanently, so deletion could never be driven by delivery alone.
//
// The tradeoff a TTL makes explicit: a mirror that has not polled for longer
// than this window can miss a removal, so it must not trust its cursor
// indefinitely. A client offline longer than the retention window should
// cold-start from sequence zero (which the feed fully supports - see
// GalleryDeltaRequest.Since) rather than resuming, and reconcile by treating
// anything it holds that the feed does not re-deliver as gone.
const DeltaTombstoneRetention = 30 * 24 * time.Hour

// deltaRow is the common shape deltaFeed merges galleryPhotos candidates and
// galleryPendingTombstones candidates into before turning them into
// GalleryDeltaItems, so the two sources can be paged and interleaved through
// one seq-ordered sequence without duplicating the assembly logic below.
type deltaRow struct {
	seq int64

	// precomputed is true for a row sourced from galleryPendingTombstones:
	// spaceProviderId/spacePath already carry the tombstone's Space identity,
	// computed at folder-removal time, because by the time these rows are
	// read the physical document may no longer translate under any of the
	// user's current folders (that is exactly why the folder was removed) -
	// see recordRemovalTombstones. precomputed is always a tombstone; there
	// is no precomputed non-tombstone row.
	precomputed     bool
	spaceProviderId string
	spacePath       string

	// only meaningful when precomputed is false - the physical candidate to
	// translate/evaluate against the user's CURRENT folders, exactly like
	// the listing does.
	photo GalleryPhoto
}

// deltaFeed returns one page of everything that changed in userId's gallery
// after req.Since, translated to SPACE paths via the same
// resolveFoldersForUser/translate the listing uses (see query.go) for
// everything except pre-computed folder-removal tombstones - this remains
// the feed's entire access-control mechanism, deliberately not a second one.
//
// Ordering and paging follow the seq index exactly like the listing follows
// the (capturedAt, _id) index: a keyset/seek cursor, never skip/limit, so a
// page can never skip or repeat a document regardless of how many polls or
// pages are involved, and a cursor persisted by the client survives an app
// restart untouched (it is a position in the index, not a page number).
//
// Two sources share the same seq space and are merged in seq order:
//
//  1. galleryPhotos, exactly like the listing's candidate scan. A candidate
//     is emitted as a tombstone when it is flagged Deleted; a candidate that
//     no longer translates under any of the user's CURRENT folders is simply
//     skipped (not emitted at all) - it was never this user's to begin with,
//     or its folder was removed and (2) below is what tombstones it.
//     bumpSeqForPrefix (called from addSourceFolder) is what makes a folder
//     ADD show up here: it puts a folder's already-ingested, otherwise-
//     untouched documents back into the seq-ordered scan range.
//  2. galleryPendingTombstones, scoped to req.UserId ONLY (a real filter,
//     unlike galleryPhotos - this collection is per-user by construction).
//     recordRemovalTombstones (called from removeSourceFolder) is what
//     populates it: a folder REMOVE tombstones its already-ingested
//     documents by SpaceProviderId/SpacePath computed AT REMOVAL TIME,
//     because by the time this function runs later, the removed folder no
//     longer exists to translate through and (1) above could not produce an
//     identity for them at all.
//
// Both sources are additionally bounded above by the allocator's safe
// watermark, captured once per request. Without that bound this function
// would happily serve a high sequence while a lower one was still being
// written, advancing the client's cursor past a document it never received -
// see sequenceAllocator's docs for why that is silent, permanent mirror data
// loss rather than a transient hiccup. Anything above the watermark is simply
// left for the next poll, a few milliseconds later.
func (g *GalleryProvider) deltaFeed(ctx context.Context, req *GalleryDeltaRequest) *GalleryDeltaResponse {
	if req.UserId == "" {
		return &GalleryDeltaResponse{Error: "userId is required"}
	}

	pageSize := req.PageSize
	if pageSize <= 0 {
		pageSize = DefaultDeltaPageSize
	}
	if pageSize > MaxDeltaPageSize {
		pageSize = MaxDeltaPageSize
	}

	cursor, err := decodeDeltaCursor(req.Cursor)
	if err != nil {
		return &GalleryDeltaResponse{Error: err.Error()}
	}

	// pos seeds the seek position: either the in-progress page's cursor, or
	// (for the first request of a poll) req.Since itself - "everything with
	// seq > Since" is nothing more than seeking from Since with no items
	// examined yet.
	pos := req.Since
	if req.Cursor != "" {
		pos = cursor.seq
	}

	folders, err := g.resolveFoldersForUser(ctx, req.UserId)
	if err != nil {
		return &GalleryDeltaResponse{Error: err.Error()}
	}

	// Captured once, before any scanning: the highest sequence it is safe to
	// serve without stepping over a lower one that is still being written.
	// Re-reading it mid-scan would be pointless and slightly worse - a value
	// that rose between batches could let a later batch serve past a gap an
	// earlier batch had correctly stopped short of.
	watermark := g.sequences.watermark()

	items := make([]GalleryDeltaItem, 0, pageSize)
	// seeded from pos rather than req.Since: on a continuation page (Cursor
	// set), pos already sits at the in-progress page's seek position, ahead
	// of req.Since. Seeding from req.Since here would let a final,
	// zero-row page (the common case: a drain that lands exactly on a page
	// boundary and finds nothing further waiting beyond it) report
	// NextSince = req.Since, regressing the client's cursor back below
	// items already delivered on the pages before this one - the client
	// would then re-request and re-receive them on its very next poll.
	maxSeq := pos
	exhausted := false

	for len(items) < pageSize && !exhausted {
		rows, batchFullyWalked, findErr := g.nextDeltaRows(ctx, req.UserId, pos, watermark)
		if findErr != nil {
			return &GalleryDeltaResponse{Error: findErr.Error()}
		}

		for _, row := range rows {
			pos = row.seq
			if pos > maxSeq {
				maxSeq = pos
			}

			item, emit := deltaItemFor(row, folders)
			if !emit {
				continue
			}
			items = append(items, item)

			if len(items) == pageSize {
				batchFullyWalked = false
				break
			}
		}

		if batchFullyWalked {
			exhausted = true
		}
	}

	resp := &GalleryDeltaResponse{Items: items}
	if len(items) == pageSize && !exhausted {
		resp.HasMore = true
		resp.NextCursor = encodeDeltaCursor(pos)
		resp.NextSince = req.Since
	} else {
		resp.NextSince = maxSeq
	}
	return resp
}

// deltaItemFor decides whether row produces a delivered GalleryDeltaItem and
// builds it if so. emit is false exactly when a galleryPhotos candidate does
// not currently translate under any of the user's folders - see deltaFeed's
// docs on why that case is silently skipped rather than emitted as an
// identity-less tombstone.
func deltaItemFor(row deltaRow, folders []resolvedFolder) (GalleryDeltaItem, bool) {
	if row.precomputed {
		return GalleryDeltaItem{
			ProviderId: row.spaceProviderId,
			Path:       row.spacePath,
			Seq:        row.seq,
			Tombstone:  true,
		}, true
	}

	p := row.photo
	spaceProviderId, spacePath, ok := translate(folders, p.ProviderId, p.Path)
	if !ok {
		return GalleryDeltaItem{}, false
	}

	if p.Deleted {
		return GalleryDeltaItem{
			ProviderId: spaceProviderId,
			Path:       spacePath,
			Seq:        p.Seq,
			Tombstone:  true,
		}, true
	}

	return GalleryDeltaItem{
		ProviderId:       spaceProviderId,
		Path:             spacePath,
		Seq:              p.Seq,
		CapturedAt:       p.CapturedAt,
		CapturedAtSource: p.CapturedAtSource,
		Width:            p.Width,
		Height:           p.Height,
		Orientation:      p.Orientation,
		Size:             p.Size,
		Mime:             p.Mime,
		Unsupported:      p.Unsupported,
		MetadataPending:  p.MetadataPending,
	}, true
}

// nextDeltaRows pulls the next batch of candidates strictly after seq pos and
// no higher than watermark, merged in seq order from galleryPhotos and this
// user's galleryPendingTombstones. batchFullyWalked reports whether both
// underlying batches were short (i.e. exhausted), following the same
// "distinguish end-of-data from page-filled-up" convention listPhotos uses
// (query.go).
func (g *GalleryProvider) nextDeltaRows(ctx context.Context, userId string, pos int64, watermark int64) ([]deltaRow, bool, error) {
	photoBatch, photosShort, err := g.nextPhotoRows(ctx, pos, watermark)
	if err != nil {
		return nil, false, err
	}

	tombstoneBatch, tombstonesShort, err := g.nextTombstoneRows(ctx, userId, pos, watermark)
	if err != nil {
		return nil, false, err
	}

	rows := make([]deltaRow, 0, len(photoBatch)+len(tombstoneBatch))
	rows = append(rows, photoBatch...)
	rows = append(rows, tombstoneBatch...)
	// both sources are individually seq-ordered (each is a sorted Mongo
	// query); a stable sort of their concatenation merges them into one
	// overall seq-ordered sequence, exactly what a k-way merge would produce
	// for two sources this small (a page's worth from each).
	sortDeltaRows(rows)

	return rows, photosShort && tombstonesShort, nil
}

func sortDeltaRows(rows []deltaRow) {
	// insertion sort: batches are already individually sorted and bounded by
	// deltaScanBatchSize, so this is cheap and avoids importing sort just for
	// a stable merge of two short sorted slices.
	for i := 1; i < len(rows); i++ {
		for j := i; j > 0 && rows[j].seq < rows[j-1].seq; j-- {
			rows[j], rows[j-1] = rows[j-1], rows[j]
		}
	}
}

func (g *GalleryProvider) nextPhotoRows(ctx context.Context, pos int64, watermark int64) ([]deltaRow, bool, error) {
	filter := bson.M{"seq": bson.M{"$gt": pos, "$lte": watermark}}
	findOpts := options.Find().SetSort(deltaSort).SetLimit(int64(deltaScanBatchSize))

	cur, err := g.photos.Find(ctx, filter, findOpts)
	if err != nil {
		return nil, false, err
	}
	defer cur.Close(ctx)

	var batch []GalleryPhoto
	if err := cur.All(ctx, &batch); err != nil {
		return nil, false, err
	}

	rows := make([]deltaRow, len(batch))
	for i, p := range batch {
		rows[i] = deltaRow{seq: p.Seq, photo: p}
	}
	return rows, len(batch) < deltaScanBatchSize, nil
}

func (g *GalleryProvider) nextTombstoneRows(ctx context.Context, userId string, pos int64, watermark int64) ([]deltaRow, bool, error) {
	filter := bson.M{"userId": userId, "seq": bson.M{"$gt": pos, "$lte": watermark}}
	findOpts := options.Find().SetSort(deltaSort).SetLimit(int64(deltaScanBatchSize))

	cur, err := g.pendingTombstones.Find(ctx, filter, findOpts)
	if err != nil {
		return nil, false, err
	}
	defer cur.Close(ctx)

	var batch []pendingTombstone
	if err := cur.All(ctx, &batch); err != nil {
		return nil, false, err
	}

	rows := make([]deltaRow, len(batch))
	for i, t := range batch {
		rows[i] = deltaRow{
			seq:             t.Seq,
			precomputed:     true,
			spaceProviderId: t.SpaceProviderId,
			spacePath:       t.SpacePath,
		}
	}
	return rows, len(batch) < deltaScanBatchSize, nil
}

// bumpSeqForPrefix bulk-advances Seq on every galleryPhotos document whose
// physical (providerId, path) falls under the given prefix, without
// otherwise touching the document.
//
// This is the mechanism that makes a folder ADD show up in the delta feed:
// adding a Gallery Source Folder can make already-ingested documents visible
// WITHOUT changing the documents themselves - no live file-change event
// fires, so nothing would otherwise advance their Seq, and they would never
// re-enter a "seq > since" scan. Bumping Seq puts them back in range;
// deltaFeed's per-document re-resolution against the user's CURRENT folders
// is what then decides whether to emit them (translate succeeds now that
// the folder exists), exactly as it does for any other reason a document's
// Seq might have moved.
//
// REMOVE does NOT use this: unlike ADD, by the time a removed folder's
// documents would be re-scanned, translate can no longer produce a Space
// identity for them (the folder that resolved them is gone) - see
// recordRemovalTombstones, which handles REMOVE by recording the identity
// AT REMOVAL TIME instead of trying to reconstruct it later.
//
// Every matched document gets its OWN freshly allocated sequence value
// (never the same value copied onto many documents) so ordering and
// uniqueness stay exactly what nextSequence guarantees, and so that if a
// live event lands on one of these documents concurrently, it is not lost
// or overwritten - each write, whichever call site, does its own
// find-and-modify-style read of the next counter value.
//
// Called (via startSeqBump, in the background) from addSourceFolder. The
// cost is proportional to the number of already-ingested documents under the
// one folder being added, not the size of the shared read model - the same
// cost shape backfill already accepts for ADD.
func (g *GalleryProvider) bumpSeqForPrefix(ctx context.Context, p prefix) error {
	filter := prefixFilter(p)

	cur, err := g.photos.Find(ctx, filter, options.Find().SetProjection(bson.M{"_id": 1}))
	if err != nil {
		return fmt.Errorf("finding documents under prefix %s/%s to bump: %w", p.providerId, p.path, err)
	}
	defer cur.Close(ctx)

	var docs []struct {
		Id any `bson:"_id"`
	}
	if err := cur.All(ctx, &docs); err != nil {
		return fmt.Errorf("finding documents under prefix %s/%s to bump: %w", p.providerId, p.path, err)
	}

	for _, d := range docs {
		err := g.withSequence(ctx, func(seq int64) error {
			_, err := g.photos.UpdateByID(ctx, d.Id, bson.M{"$set": bson.M{"seq": seq}})
			return err
		})
		if err != nil {
			return fmt.Errorf("bumping delta sequence for %v: %w", d.Id, err)
		}
	}

	return nil
}

// recordRemovalTombstones is REMOVE's counterpart to bumpSeqForPrefix: for
// every galleryPhotos document physically under removedFolder's prefix, it
// inserts one galleryPendingTombstones row for userId, carrying the Space
// identity removedFolder.toSpacePath computes for that document RIGHT NOW -
// while the folder still exists to translate through.
//
// This split (a dedicated, per-user, pre-computed tombstone record) rather
// than reusing bumpSeqForPrefix for REMOVE too exists because of a real
// asymmetry between ADD and REMOVE: an ADDed folder's documents are still
// translatable at the time deltaFeed later re-scans them (the folder now
// exists), but a REMOVEd folder's documents are NOT - by the time deltaFeed
// scans galleryPhotos again, the folder that used to resolve their Space
// path is gone, so translate() can never again produce an identity for them
// through that path. The identity has to be captured now or never.
//
// A pending tombstone is scoped to exactly the removing user - the same
// physical document could be visible to other users (or the same user
// through another folder) whose view is completely unaffected, since this
// writes only to the small per-user galleryPendingTombstones collection, not
// to the shared galleryPhotos document at all.
func (g *GalleryProvider) recordRemovalTombstones(ctx context.Context, userId string, removedFolder resolvedFolder) error {
	filter := prefixFilter(prefix{providerId: removedFolder.providerId, path: removedFolder.path})

	cur, err := g.photos.Find(ctx, filter, options.Find().SetProjection(bson.M{"providerId": 1, "path": 1}))
	if err != nil {
		return fmt.Errorf("finding documents under removed folder prefix %s/%s: %w", removedFolder.providerId, removedFolder.path, err)
	}
	defer cur.Close(ctx)

	var docs []struct {
		ProviderId string `bson:"providerId"`
		Path       string `bson:"path"`
	}
	if err := cur.All(ctx, &docs); err != nil {
		return fmt.Errorf("finding documents under removed folder prefix %s/%s: %w", removedFolder.providerId, removedFolder.path, err)
	}

	for _, d := range docs {
		rest, ok := removedFolder.contains(d.ProviderId, d.Path)
		if !ok {
			continue
		}
		err := g.withSequence(ctx, func(seq int64) error {
			row := pendingTombstone{
				UserId:          userId,
				SpaceProviderId: removedFolder.spaceProviderId,
				SpacePath:       removedFolder.toSpacePath(rest),
				Seq:             seq,
				CreatedAt:       time.Now(),
			}
			_, err := g.pendingTombstones.InsertOne(ctx, row)
			return err
		})
		if err != nil {
			return fmt.Errorf("recording removal tombstone for %s/%s: %w", d.ProviderId, d.Path, err)
		}
	}

	return nil
}

// startSeqBump runs bumpSeqForPrefix in the background and returns
// immediately, following the same shape as startBackfill (backfill.go) and
// for the same reason: the ADD request/reply that triggers it must not
// block on walking every already-ingested document under the folder. g.wg
// is the same WaitGroup Stop() drains for ingestion and backfill, so a bump
// in flight at shutdown is still waited for rather than abandoned
// mid-write.
func (g *GalleryProvider) startSeqBump(p prefix) {
	g.wg.Add(1)
	go func() {
		defer g.wg.Done()
		if err := g.bumpSeqForPrefix(g.backfillCtx, p); err != nil {
			g.log.Error("failed to bump delta sequence for gallery source folder addition; the delta feed may not reflect this folder change until something else touches the affected documents",
				"error", err, "providerId", p.providerId, "path", p.path)
		}
	}()
}

// startRemovalTombstoneSweep runs recordRemovalTombstones in the background
// and returns immediately, for the same reason startSeqBump does: REMOVE's
// request/reply must not block on walking every already-ingested document
// under the removed folder.
func (g *GalleryProvider) startRemovalTombstoneSweep(userId string, removedFolder resolvedFolder) {
	g.wg.Add(1)
	go func() {
		defer g.wg.Done()
		if err := g.recordRemovalTombstones(g.backfillCtx, userId, removedFolder); err != nil {
			g.log.Error("failed to record removal tombstones for gallery source folder removal; the delta feed may not reflect this removal until something else surfaces it",
				"error", err, "userId", userId, "providerId", removedFolder.providerId, "path", removedFolder.path)
		}
	}()
}

// prefixFilter builds the Mongo filter matching every galleryPhotos document
// physically at or under p, using the same directory-boundary-safe path
// range as file-indexer's paged prefix query - see prefixBounds.
func prefixFilter(p prefix) bson.M {
	filter := bson.M{"providerId": p.providerId}
	if p.path != "/" {
		lower, upper := prefixBounds(p.path)
		filter["$or"] = []bson.M{
			{"path": p.path},
			{"path": bson.M{"$gte": lower, "$lt": upper}},
		}
	}
	return filter
}

// prefixBounds computes the half-open path range [lower, upper) that
// contains every descendant of clean (a normalized, non-root physical path),
// respecting directory boundaries in both directions - the same scheme
// file-indexer's paged prefix query (file-indexer/fileindexer/list.go) uses,
// reimplemented here because this package has no dependency on that one and
// the technique is a handful of lines: descendants are delimited by "/", so
// lower is clean+"/", and the exclusive upper bound is clean+"0" since '/'
// (0x2F) is immediately followed by '0' (0x30) in byte order - a sibling
// like "/Photos2" or "/Photos.txt" therefore falls outside the range in
// either direction, only true descendants of clean match.
func prefixBounds(clean string) (lower string, upper string) {
	clean = path.Clean(clean)
	return clean + "/", clean + "0"
}
