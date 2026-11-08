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
	"fmt"
	"time"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo/options"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/gallery/geo"
)

// currentMetadataVersion is the version of the byte-level extraction
// pipeline. Every photo carries the version of the pipeline that last
// extracted it; the sweep (this file) re-extracts anything below the current
// value, so an extraction improvement reaches photos already in the read
// model without any user action.
//
// Version history:
//
//	1 - the original pipeline: pixel dimensions, orientation, Capture Date
//	    from EXIF DateTimeOriginal (parsed as UTC - the defect ADR 0003
//	    fixes).
//	2 - the capture-time rule: Capture Date stored as a true instant with
//	    CapturedAtOffset (OffsetTimeOriginal / GPS timestamp / floating),
//	    plus GPS coordinates extraction (Lat/Lon) for place resolution.
//	3 - NaN/Inf coordinates (0/0 GPS rationals) stored as absent instead
//	    of as NaN, which broke the delta feed's JSON encoding.
//
// Live ingestion and the sweep both write this value; backfill writes 0
// (backfill never extracts - see backfill.go's metadata tension docs), so a
// backfilled placeholder is swept immediately after boot.
const currentMetadataVersion = 3

// sweepPageSize is how many documents one sweep page pulls. The sweep is
// deliberately unheroic: it competes with live ingestion and query serving
// for the File Provider, NATS and Mongo, so it walks the backlog in small
// pages with a pause between them (see sweepPagePause) rather than pegging
// the service for the length of a large gallery's catch-up.
const sweepPageSize = 50

// sweepPagePause is how long the sweep waits between pages.
const sweepPagePause = 250 * time.Millisecond

// startMetadataSweep launches the background metadata sweep on boot - see
// runMetadataSweep. Progress lives on the documents themselves
// (metadataVersion/geoVersion), so a restart simply resumes; nothing is
// stored elsewhere and nothing has to be marked done.
func (g *GalleryProvider) startMetadataSweep(ctx context.Context) {
	g.wg.Add(1)
	go func() {
		defer g.wg.Done()
		if err := g.runMetadataSweep(ctx); err != nil {
			if ctx.Err() != nil {
				// shutdown, not a failure
				return
			}
			g.log.Error("gallery metadata sweep failed", "error", err)
		}
	}()
}

// runMetadataSweep brings every non-deleted gallery photo up to the current
// extraction and place versions, in two passes:
//
//  1. Re-extraction (metadataVersion < currentMetadataVersion): the photo is
//     opened through the File Provider exactly as live ingestion does and
//     run through the current extraction. This is how the capture-time rule
//     (offset + true instant) and GPS coordinates reach photos already in
//     the read model, and it is what finally clears MetadataPending on
//     documents backfill left pending - the gap this file exists to close
//     (until now, a pending photo healed only when a live event happened to
//     touch its path again).
//
//  2. Place re-resolution (geoVersion < geo.Version, coordinates present):
//     a re-resolve from the STORED coordinates, without opening the file -
//     cheap by comparison, and what makes a regenerated geo dataset reach
//     every photo that already has coordinates.
//
// Concurrency is 1 (the sweep is one goroutine) and a pause separates
// pages. A photo whose file cannot be opened keeps its old version and is
// retried on the next boot: it is logged and skipped, never allowed to
// stall the sweep - the same per-item error handling backfill and the
// rescan heal pass use.
//
// Seq is bumped only when a field the delta feed carries actually changed
// (see feedVisibleExtractionChanged / feedVisiblePlaceChanged): a sweep that
// changed nothing but the internal version numbers resyncs no mirror. A
// restart mid-sweep resumes for free: the next boot finds exactly the
// documents still below the current versions.
func (g *GalleryProvider) runMetadataSweep(ctx context.Context) error {
	if err := g.sweepReextractPass(ctx); err != nil {
		return fmt.Errorf("re-extraction pass: %w", err)
	}
	if err := g.sweepGeoResolvePass(ctx); err != nil {
		return fmt.Errorf("geo re-resolve pass: %w", err)
	}
	return nil
}

// sweepStaleFilter is the Mongo filter selecting documents the RE-EXTRACTION
// pass still has to visit: not deleted, and either at a version below the
// current one or predating the version field entirely (pre-feature
// documents have no metadataVersion at all, and Mongo range queries do not
// match a missing field).
func sweepStaleFilter() bson.M {
	return bson.M{
		"deleted": bson.M{"$ne": true},
		"$or": bson.A{
			bson.M{"metadataVersion": bson.M{"$lt": currentMetadataVersion}},
			bson.M{"metadataVersion": bson.M{"$exists": false}},
		},
	}
}

func (g *GalleryProvider) sweepReextractPass(ctx context.Context) error {
	var afterID *primitive.ObjectID
	for {
		photos, err := g.nextSweepBatch(ctx, sweepStaleFilter(), afterID)
		if err != nil {
			return err
		}
		if len(photos) == 0 {
			return nil
		}
		afterID = &photos[len(photos)-1].Id

		for _, photo := range photos {
			if err := g.sweepReextract(ctx, photo); err != nil {
				return err
			}
		}

		if len(photos) < sweepPageSize {
			return nil
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(sweepPagePause):
		}
	}
}

// nextSweepBatch returns the oldest (by _id) up to sweepPageSize documents
// matching filter, strictly after afterID when it is non-nil.
//
// The paging is cursor-based (each page starts past the previous page's last
// _id), NOT "re-query the same filter": a photo the pass cannot process (a
// file that cannot be opened, say) keeps its old version and would otherwise
// sit at the head of the same oldest-first sort forever, re-fetched and
// re-failed on every page - the sweep would never reach the photos behind
// it and never terminate while a whole page's worth of files were
// unreadable (a File Provider offline at boot, say). With the cursor, a
// failing photo is skipped exactly once per boot - it stays in the stale
// pool for the next boot to retry - and later photos are still processed,
// which is the ticket's "skipped, never allowed to stall the sweep" rule.
func (g *GalleryProvider) nextSweepBatch(ctx context.Context, filter bson.M, afterID *primitive.ObjectID) ([]GalleryPhoto, error) {
	if afterID != nil {
		filter["_id"] = bson.M{"$gt": *afterID}
	}
	findOpts := options.Find().
		SetSort(bson.D{{Key: "_id", Value: 1}}).
		SetLimit(int64(sweepPageSize))

	cur, err := g.photos.Find(ctx, filter, findOpts)
	if err != nil {
		return nil, fmt.Errorf("finding sweep candidates: %w", err)
	}
	defer cur.Close(ctx)

	var photos []GalleryPhoto
	if err := cur.All(ctx, &photos); err != nil {
		return nil, fmt.Errorf("reading sweep candidates: %w", err)
	}
	return photos, nil
}

// sweepReextract re-extracts ONE photo and upserts the result, guarded so a
// live event racing the sweep for the same path always wins (the write only
// lands while the document is still below the current version and still not
// deleted - a live event writes the current version, so whichever order they
// commit in, the document ends at the current version with the live event's
// data, or the sweep's data if the live event never landed).
//
// ModTime is carried through only when the photo's Capture Date actually
// came from rung two (the file's real modification time) - exactly the same
// rule healPendingMetadata uses: feeding resolveCaptureDate a value that was
// never a modification time (the "indexed" rung) would let it masquerade as
// one. When EXIF still yields nothing, rung two therefore re-derives the
// same value the document already holds, and the extraction counts as
// unchanged.
func (g *GalleryProvider) sweepReextract(ctx context.Context, photo GalleryPhoto) error {
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

	meta, capturedAt, offset, source, err := g.extractForEvent(ctx, ev)
	if err != nil {
		// The file is gone, or its provider is unreachable. Keep the old
		// version: the document stays in the stale pool and is retried on
		// the next boot. It must not stall the sweep - later photos are
		// still processed.
		g.log.Warn("gallery metadata sweep: could not re-extract photo; keeping old version",
			"error", err, "providerId", photo.ProviderId, "path", photo.Path)
		return nil
	}

	lat, lon, place := resolvePhotoPlace(meta)

	// The write is guarded on the document still being stale AND still not
	// deleted: a live event for the same path (or a deletion) that commits
	// first makes this write a no-op, rather than a stale re-extraction
	// overwriting fresher data or resurrecting a tombstone.
	filter := bson.M{
		"providerId": photo.ProviderId,
		"path":       photo.Path,
		"deleted":    bson.M{"$ne": true},
		"$or": bson.A{
			bson.M{"metadataVersion": bson.M{"$lt": currentMetadataVersion}},
			bson.M{"metadataVersion": bson.M{"$exists": false}},
		},
	}

	if feedVisibleExtractionChanged(photo, meta, capturedAt, offset, source, lat, lon, place) {
		err = g.withSequence(ctx, func(seq int64) error {
			update := bson.M{"$set": bson.M{
				"capturedAt":       capturedAt,
				"capturedAtOffset": offset,
				"capturedAtSource": source,
				"width":            meta.Width,
				"height":           meta.Height,
				"orientation":      meta.Orientation,
				"size":             photo.Size,
				"mime":             photo.Mime,
				"unsupported":      meta.Unsupported,
				"metadataPending":  false,
				"metadataVersion":  currentMetadataVersion,
				"lat":              lat,
				"lon":              lon,
				"place":            place,
				"geoVersion":       geoVersionFor(place),
				"seq":              seq,
			}}
			_, err := g.photos.UpdateOne(ctx, filter, update)
			return err
		})
		if err != nil {
			return fmt.Errorf("sweep upsert %s/%s: %w", photo.ProviderId, photo.Path, err)
		}
		return nil
	}

	// Nothing the feed carries changed - advance the bookkeeping only, with
	// no Seq bump, so a re-extraction that changed nothing does not resync
	// every mirror.
	update := bson.M{"$set": bson.M{
		"metadataPending": false,
		"metadataVersion": currentMetadataVersion,
		"lat":             lat,
		"lon":             lon,
		"place":           place,
		"geoVersion":      geoVersionFor(place),
	}}
	if _, err := g.photos.UpdateOne(ctx, filter, update); err != nil {
		return fmt.Errorf("sweep version bump %s/%s: %w", photo.ProviderId, photo.Path, err)
	}
	return nil
}

// sweepGeoResolvePass re-resolves Places from stored coordinates for photos
// whose geoVersion is below the current dataset version. It never opens the
// File Provider: the coordinates were already extracted, and the only thing
// that changed is the resolution itself (a regenerated or improved dataset).
//
// Seq bumps only when the resolved Place actually changed, so a dataset
// regeneration that resolves the same Places for everything (the common
// case) resyncs no mirror.
func (g *GalleryProvider) sweepGeoResolvePass(ctx context.Context) error {
	filter := bson.M{
		"deleted":         bson.M{"$ne": true},
		"metadataVersion": currentMetadataVersion,
		"geoVersion":      bson.M{"$lt": geo.Version},
		"lat":             bson.M{"$ne": nil},
		"lon":             bson.M{"$ne": nil},
	}

	var afterID *primitive.ObjectID
	for {
		photos, err := g.nextSweepBatch(ctx, filter, afterID)
		if err != nil {
			return err
		}
		if len(photos) == 0 {
			return nil
		}
		afterID = &photos[len(photos)-1].Id

		for _, photo := range photos {
			if photo.Lat == nil || photo.Lon == nil {
				continue
			}
			place := geo.Resolve(*photo.Lat, *photo.Lon)

			writeFilter := bson.M{
				"providerId": photo.ProviderId,
				"path":       photo.Path,
				"geoVersion": bson.M{"$lt": geo.Version},
			}

			if !placeEqual(photo.Place, place) {
				err = g.withSequence(ctx, func(seq int64) error {
					update := bson.M{"$set": bson.M{
						"place":      place,
						"geoVersion": geo.Version,
						"seq":        seq,
					}}
					_, err := g.photos.UpdateOne(ctx, writeFilter, update)
					return err
				})
			} else {
				update := bson.M{"$set": bson.M{"geoVersion": geo.Version}}
				_, err = g.photos.UpdateOne(ctx, writeFilter, update)
			}
			if err != nil {
				return fmt.Errorf("sweep geo re-resolve %s/%s: %w", photo.ProviderId, photo.Path, err)
			}
		}

		if len(photos) < sweepPageSize {
			return nil
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(sweepPagePause):
		}
	}
}

// geoVersionFor is the geoVersion a photo with the given place should carry
// after extraction: geo.Version when a place was (re)resolved, 0 when there
// are no coordinates to resolve - a later dataset bump must not pick up a
// photo with nothing to resolve from.
func geoVersionFor(place *geo.Place) int {
	if place == nil {
		return 0
	}
	return geo.Version
}

// feedVisibleExtractionChanged reports whether a re-extraction produced
// anything the delta feed would deliver differently for this photo. Size and
// Mime are not compared: the sweep's event is built from the document's own
// values, so they are unchanged by construction.
func feedVisibleExtractionChanged(
	photo GalleryPhoto,
	meta photoMetadata,
	capturedAt int64,
	offset *int,
	source string,
	lat, lon *float64,
	place *geo.Place,
) bool {
	if photo.MetadataPending {
		// clearing the pending flag is itself a feed-visible change: the
		// mirror's row says "provisional" until the feed says otherwise
		return true
	}
	if photo.CapturedAt != capturedAt {
		return true
	}
	if photo.CapturedAtSource != source {
		return true
	}
	if !intPtrEqual(photo.CapturedAtOffset, offset) {
		return true
	}
	if photo.Width != meta.Width ||
		photo.Height != meta.Height ||
		photo.Orientation != meta.Orientation {
		return true
	}
	if photo.Unsupported != meta.Unsupported {
		return true
	}
	if !floatPtrEqual(photo.Lat, lat) || !floatPtrEqual(photo.Lon, lon) {
		return true
	}
	if !placeEqual(photo.Place, place) {
		return true
	}
	return false
}

// resolvePhotoPlace turns extraction output into coordinates and a resolved
// Place - the single seam live ingestion and the sweep share, so both store
// exactly the same shape for the same file. No coordinates means no place
// and a geoVersion of 0 (nothing to re-resolve later).
func resolvePhotoPlace(meta photoMetadata) (lat, lon *float64, place *geo.Place) {
	if meta.Lat == nil || meta.Lon == nil {
		return nil, nil, nil
	}
	return meta.Lat, meta.Lon, geo.Resolve(*meta.Lat, *meta.Lon)
}

func intPtrEqual(a, b *int) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

func floatPtrEqual(a, b *float64) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

// placeEqual compares stored and freshly resolved Places. nil (no place)
// and an all-empty Place are the same thing semantically, so they compare
// equal - a re-resolve that yields "no place" for a photo that had an empty
// stored place must not bump Seq for it.
func placeEqual(a, b *geo.Place) bool {
	if a == nil || b == nil {
		if a == nil && b == nil {
			return true
		}
		other := a
		if other == nil {
			other = b
		}
		return other.IsEmpty()
	}
	return *a == *b
}
