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
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/messaging"
)

// photoReplayMarkerId is the _id of the one-off photo replay's marker
// document in the gallerySequenceCounters collection (see
// dotfileSweepMarkerId). Fields: lastId (ObjectID of the last galleryPhotos
// document published, the resume point) and done (bool).
//
// To re-run the replay (e.g. after wiping the gallery_ai database), delete
// the marker document and restart gallery with ai.enabled set:
//
//	db.gallerySequenceCounters.deleteOne({_id: "photoReplay"})
const photoReplayMarkerId = "photoReplay"

const photoReplayBatchSize = 500

// startPhotoReplay runs the one-off replay in the background (tracked on
// g.wg like the dotfile sweep). A failure is logged and retried from the
// persisted lastId on the next restart. A no-op unless ai.enabled is set.
func (g *GalleryProvider) startPhotoReplay(ctx context.Context) {
	if g.js == nil || !g.aiEnabled {
		return
	}
	g.wg.Add(1)
	go func() {
		defer g.wg.Done()
		if err := g.runPhotoReplay(ctx); err != nil {
			g.log.Error("failed to replay existing gallery photos to gallery-ai; will resume on next restart",
				"error", err)
		}
	}()
}

// runPhotoReplay publishes an upserted GalleryPhotoChangedEvent (with the
// document's current seq) for every non-deleted galleryPhotos document,
// ordered by _id, in batches. After each batch the last published _id is
// persisted in the marker so a restart resumes after it; the marker is set
// done at the end. Republishing is harmless: gallery-ai drops events whose
// seq it has already processed.
func (g *GalleryProvider) runPhotoReplay(ctx context.Context) (err error) {
	var marker struct {
		LastId primitive.ObjectID `bson:"lastId"`
		Done   bool               `bson:"done"`
	}
	err = g.sequences.counters.FindOne(ctx, bson.M{"_id": photoReplayMarkerId}).Decode(&marker)
	if err != nil && err != mongo.ErrNoDocuments {
		return fmt.Errorf("reading photo replay marker: %w", err)
	}
	if marker.Done {
		g.log.Debug("photo replay already done; skipping")
		return nil
	}

	lastId := marker.LastId
	published := 0

	remaining := bson.M{"deleted": bson.M{"$ne": true}}
	if !lastId.IsZero() {
		remaining["_id"] = bson.M{"$gt": lastId}
	}
	total, countErr := g.photos.CountDocuments(ctx, remaining)
	if countErr != nil {
		return fmt.Errorf("counting gallery photos to replay: %w", countErr)
	}
	job := messaging.NewJob(g.nc, "gallery.replay", "Replaying gallery photos to gallery-ai")
	defer job.Close()
	job.Progress(0, total, "")
	defer func() {
		switch {
		case err == nil:
			job.Complete(fmt.Sprintf("%d photos replayed", published))
		case ctx.Err() == nil: // a shutdown is resumed on restart, not a failure
			job.Fail(err)
		}
	}()
	for {
		filter := bson.M{"deleted": bson.M{"$ne": true}}
		if !lastId.IsZero() {
			filter["_id"] = bson.M{"$gt": lastId}
		}
		findOpts := options.Find().
			SetSort(bson.M{"_id": 1}).
			SetLimit(photoReplayBatchSize).
			SetProjection(bson.M{"providerId": 1, "path": 1, "seq": 1})
		cur, err := g.photos.Find(ctx, filter, findOpts)
		if err != nil {
			return fmt.Errorf("finding gallery photos to replay: %w", err)
		}
		var docs []struct {
			Id         primitive.ObjectID `bson:"_id"`
			ProviderId string             `bson:"providerId"`
			Path       string             `bson:"path"`
			Seq        int64              `bson:"seq"`
		}
		err = cur.All(ctx, &docs)
		if err != nil {
			return fmt.Errorf("finding gallery photos to replay: %w", err)
		}
		if len(docs) == 0 {
			break
		}

		var pubErr error
		for _, d := range docs {
			if pubErr = ctx.Err(); pubErr != nil {
				break
			}
			if pubErr = g.publishPhotoChanged(ctx, d.ProviderId, d.Path, events.GalleryPhotoUpserted, d.Seq); pubErr != nil {
				pubErr = fmt.Errorf("replaying %s/%s: %w", d.ProviderId, d.Path, pubErr)
				break
			}
			lastId = d.Id
			published++
			job.Progress(int64(published), total, "")
		}

		// persist progress up to the last photo actually published, so a
		// failed publish is retried on the next restart rather than skipped.
		if !lastId.IsZero() {
			saveCtx := ctx
			if pubErr != nil {
				saveCtx = context.WithoutCancel(ctx)
			}
			_, err = g.sequences.counters.UpdateOne(saveCtx, bson.M{"_id": photoReplayMarkerId},
				bson.M{"$set": bson.M{"lastId": lastId}}, options.Update().SetUpsert(true))
			if err != nil {
				return fmt.Errorf("saving photo replay progress: %w", err)
			}
		}
		if pubErr != nil {
			return pubErr
		}
	}

	_, err = g.sequences.counters.UpdateOne(ctx, bson.M{"_id": photoReplayMarkerId},
		bson.M{"$set": bson.M{"done": true}}, options.Update().SetUpsert(true))
	if err != nil {
		return fmt.Errorf("marking photo replay done: %w", err)
	}
	g.log.Info("photo replay complete", "published", published)
	return nil
}
