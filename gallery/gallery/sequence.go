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

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo/options"
)

// gallerySequenceCounterId is the single well-known document identifying the
// delta-feed sequence counter, in the gallerySequenceCounters collection.
// There is exactly one counter, shared by every writer (live ingestion,
// backfill, deletion) and every physical folder - the delta feed's ordering
// is global across the whole read model, not per-user or per-folder, so a
// single counter is what makes "poll from sequence N" a well-defined
// operation at all.
const gallerySequenceCounterId = "galleryPhotos"

// nextSequence atomically allocates and returns the next monotonic sequence
// value for the delta feed, via a findAndModify $inc against a single
// counter document in Mongo.
//
// This - not an in-memory counter - is what makes sequence allocation
// survive a service restart: the counter's current value is durable state in
// the same database the read model itself lives in, so a freshly started
// process resumes exactly where the last one left off instead of starting
// back at zero (which would immediately violate "never reused": a restarted
// service would hand out sequence 1 again while documents already carrying
// sequence 1 from before the restart still exist).
//
// It is also what makes allocation safe under concurrent writers: MongoDB
// executes findOneAndUpdate atomically per document, so two goroutines (an
// ingest handler and a backfill upsert, say) racing this call can never
// observe or hand out the same value - each $inc is serialized by the
// database, not by anything in this process. This matters specifically
// because ingestion, backfill and the delete path in this package all call
// it independently and concurrently (ingestParallel and backfillParallel are
// both > 1).
//
// The upsert option means the counter document is created (starting the
// sequence at 1) the first time this is ever called against a fresh
// database, with no separate initialization step required.
func (g *GalleryProvider) nextSequence(ctx context.Context) (int64, error) {
	filter := bson.M{"_id": gallerySequenceCounterId}
	update := bson.M{"$inc": bson.M{"seq": int64(1)}}
	opts := options.FindOneAndUpdate().
		SetUpsert(true).
		SetReturnDocument(options.After)

	var doc struct {
		Seq int64 `bson:"seq"`
	}
	err := g.sequenceCounters.FindOneAndUpdate(ctx, filter, update, opts).Decode(&doc)
	if err != nil {
		return 0, err
	}
	return doc.Seq, nil
}
