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

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

// dotfileSweepMarkerId is the well-known _id of the one-off dotfile sweep's
// "done" marker document, stored in the existing gallerySequenceCounters
// collection (reused rather than introducing a new collection or a
// migrations/*.json file - the sweep is code-level because it requires seq
// allocation, which a data migration cannot do). Its presence with done=true
// is what stops the sweep from re-running on every restart: a single
// conditional upsert at the end of a successful sweep is all the gating that
// is needed, since a sweep that did not finish leaves no marker behind and is
// re-run on the next start, exactly like a resumed backfill.
const dotfileSweepMarkerId = "dotfileSweepDone"

// dotfileBasenameRegex matches every physical path whose FINAL segment
// begins with ".", i.e. exactly the documents isDotfile (ingest.go) would
// have rejected on ingest/backfill. A path in this system always starts with
// "/", so anchoring on "/\." (a slash followed by a dot) and running to the
// end of the string with no further "/" selects precisely basename-dotfiles:
// "/.DS_Store", "/holidays/.foo.jpg.part", "/holidays/sub/.bar" all match;
// "/holidays/normal.jpg" and "/holidays/sub/normal.jpg" do not. This is the
// Mongo-side narrowing of the same predicate isDotfile applies in Go, kept in
// sync with it so the sweep cannot drift from the ingest filter that made the
// dotfile leak stop in the first place.
const dotfileBasenameRegex = `/\.[^/]*$`

// startDotfileSweep runs the one-off dotfile sweep in the background and
// returns immediately, mirroring startRemovalTombstoneSweep/startSeqBump/
// resumeIncompleteBackfills: Start() must return promptly regardless of how
// many stray dotfile documents are sitting in the read model, and the sweep
// is tracked on the same g.wg/g.backfillCtx Stop() drains so an in-flight
// sweep is cancelled and waited for at shutdown rather than abandoned
// mid-write.
//
// The sweep is gated by the dotfileSweepDone marker: if it is already set
// (a previous start completed the sweep) this is a no-op. A sweep that is
// interrupted before it finishes leaves no marker, so the next start re-runs
// it - re-running is safe because the sweep's Mongo filter excludes
// already-deleted documents, so previously-tombstoned dotfiles are skipped
// and only the remaining ones are processed.
func (g *GalleryProvider) startDotfileSweep(ctx context.Context) {
	g.wg.Add(1)
	go func() {
		defer g.wg.Done()
		if err := g.runDotfileSweep(ctx); err != nil {
			g.log.Error("failed to sweep pre-existing dotfile gallery photos; will retry on next restart",
				"error", err)
		}
	}()
}

// runDotfileSweep is the one-off startup sweep: it finds every galleryPhotos
// document whose final path segment begins with "." (the dotfile convention
// isDotfile encodes) and runs it through markDeleted, so each gets
// deleted:true and a freshly allocated seq - the exact same tombstone write a
// live "deleted" FileChangedEvent produces (ingest.go). The delta feed
// therefore delivers these tombstones through the same path it delivers any
// deletion, with no new tombstone source: a mirror polling past the swept
// seq values receives one tombstone per dotfile and removes it locally,
// exactly as if the file had been deleted live.
//
// Already-deleted dotfiles are excluded: markDeleted is idempotent on the
// deleted flag but NOT on seq (it always allocates a fresh value), so
// re-tombstoning an already-tombstoned document would deliver a duplicate
// tombstone to every mirror. The sweep runs at most once per database (gated
// by the marker), so this exclusion only matters for the interrupted-and-
// resumed case, where some dotfiles were tombstoned by the prior partial run
// and the rest still need to be - skipping the former is what makes a partial
// resume deliver each dotfile's tombstone exactly once across the two runs
// combined.
//
// On success the dotfileSweepDone marker is set, so subsequent restarts do
// not re-run the sweep. On failure (mid-sweep error, or context cancelled at
// shutdown) no marker is written, so the next start re-runs from scratch -
// see startDotfileSweep's docs on why that is safe.
func (g *GalleryProvider) runDotfileSweep(ctx context.Context) error {
	done, err := g.isDotfileSweepDone(ctx)
	if err != nil {
		return fmt.Errorf("checking dotfile sweep marker: %w", err)
	}
	if done {
		g.log.Debug("dotfile sweep already done; skipping")
		return nil
	}

	filter := bson.M{
		"path":    bson.M{"$regex": primitive.Regex{Pattern: dotfileBasenameRegex}},
		"deleted": bson.M{"$ne": true},
	}
	findOpts := options.Find().SetProjection(bson.M{"providerId": 1, "path": 1})

	cur, err := g.photos.Find(ctx, filter, findOpts)
	if err != nil {
		return fmt.Errorf("finding dotfile gallery photos: %w", err)
	}
	defer cur.Close(ctx)

	var docs []struct {
		ProviderId string `bson:"providerId"`
		Path       string `bson:"path"`
	}
	if err := cur.All(ctx, &docs); err != nil {
		return fmt.Errorf("finding dotfile gallery photos: %w", err)
	}

	swept := 0
	for _, d := range docs {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		if !isDotfile(d.Path) {
			continue
		}

		if err := g.markDeleted(ctx, d.ProviderId, d.Path); err != nil {
			return fmt.Errorf("tombstoning dotfile %s/%s: %w", d.ProviderId, d.Path, err)
		}
		swept++
	}

	if err := g.markDotfileSweepDone(ctx); err != nil {
		return fmt.Errorf("marking dotfile sweep done: %w", err)
	}

	g.log.Info("dotfile sweep complete", "swept", swept)
	return nil
}

// isDotfileSweepDone reports whether the one-off dotfile sweep has already
// run to completion against this database. A missing marker document (the
// fresh-database case, or a sweep that never finished) reports false.
func (g *GalleryProvider) isDotfileSweepDone(ctx context.Context) (bool, error) {
	var doc struct {
		Done bool `bson:"done"`
	}
	err := g.sequences.counters.FindOne(ctx, bson.M{"_id": dotfileSweepMarkerId}).Decode(&doc)
	if err == mongo.ErrNoDocuments {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return doc.Done, nil
}

// markDotfileSweepDone writes the dotfileSweepDone marker, upserting so the
// document is created on the first ever successful sweep. Called only after
// the sweep has completed without error, so the marker's presence is a
// reliable signal that every dotfile present at that moment was tombstoned.
func (g *GalleryProvider) markDotfileSweepDone(ctx context.Context) error {
	filter := bson.M{"_id": dotfileSweepMarkerId}
	update := bson.M{"$set": bson.M{"done": true}}
	opts := options.Update().SetUpsert(true)
	if _, err := g.sequences.counters.UpdateOne(ctx, filter, update, opts); err != nil {
		return err
	}
	return nil
}
