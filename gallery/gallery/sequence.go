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
	"math"
	"sync"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
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

// unboundedWatermark is the watermark reported when nothing is in flight:
// every sequence ever allocated has also been written, so there is nothing
// to hold the feed back.
const unboundedWatermark = int64(math.MaxInt64)

// sequenceAllocator hands out delta-feed sequence values AND tracks which of
// them have been allocated but not yet written, so the feed can refuse to
// serve past a gap.
//
// THE RACE THIS EXISTS TO CLOSE. Allocation ($inc on the counter) and the
// document write that stamps the allocated value are necessarily two separate
// operations, and the writers are genuinely concurrent (ingestParallel = 4,
// backfillParallel = 2, plus delete/folder-sweep paths). So writer B can
// allocate seq 6 and commit its write while writer A, holding seq 5, has not
// committed yet. A delta poll landing in that window would see 6, serve it,
// and advance the client's cursor to 6 - and seq 5's document, committed a
// moment later, would then be BELOW the client's cursor forever. That photo
// would be permanently missing from that mirror, with no later poll able to
// recover it and nothing anywhere reporting an error.
//
// The fix is a safe watermark: an allocated-but-unwritten sequence is held in
// inFlight until its write returns, and the feed never serves at or beyond
// the lowest in-flight value (see watermark). Seq 6 is simply not served
// while seq 5 is outstanding; the very next poll, once 5 has landed, serves
// both in order.
//
// SINGLE-INSTANCE ASSUMPTION - READ THIS BEFORE SCALING OUT. inFlight is
// per-process memory, so this is exact for ONE gallery service instance and
// ONLY one. Run two instances against the same database and each sees only
// its own in-flight allocations: instance A would happily serve seq 6 while
// instance B still holds seq 5 unwritten, silently reintroducing exactly the
// data-loss bug described above. Horizontally scaling the gallery service
// therefore REQUIRES replacing this with a mechanism that is safe across
// processes - e.g. only serving items whose write landed more than a small
// interval ago (a time-based safety lag, trading a little feed latency for
// multi-instance safety), or a shared/coordinated watermark. The rest of the
// service has no other single-instance assumption; this one does.
type sequenceAllocator struct {
	counters *mongo.Collection

	mu       sync.Mutex
	inFlight map[int64]struct{}
}

func newSequenceAllocator(counters *mongo.Collection) *sequenceAllocator {
	return &sequenceAllocator{
		counters: counters,
		inFlight: make(map[int64]struct{}),
	}
}

// allocate atomically takes the next monotonic sequence value and records it
// as in flight. The returned release function MUST be called once the write
// stamping that value has completed (successfully or not) - until then the
// feed will not serve this value or anything above it.
//
// Durability across restarts comes from the counter living in Mongo rather
// than in memory: a freshly started process resumes from the persisted value
// instead of handing out 1 again while documents already carrying 1 exist.
// Uniqueness under concurrency comes from findOneAndUpdate being atomic per
// document - the database, not this process, serializes the $inc.
//
// The counter mutex is deliberately held ACROSS the Mongo round trip rather
// than only around the map insert. Releasing it earlier would open a window
// where a value has been allocated but is not yet in inFlight, during which
// watermark could report "nothing in flight" and the feed could serve past
// that very allocation - the exact gap this type exists to prevent. The cost
// is that sequence allocation is serialized process-wide; with the modest
// writer concurrency this service runs (single digits) that is one short
// round trip of contention, not a throughput concern.
//
// The upsert option means the counter document is created (starting the
// sequence at 1) the first time this is ever called against a fresh
// database, with no separate initialization step required.
func (a *sequenceAllocator) allocate(ctx context.Context) (int64, func(), error) {
	a.mu.Lock()
	defer a.mu.Unlock()

	filter := bson.M{"_id": gallerySequenceCounterId}
	update := bson.M{"$inc": bson.M{"seq": int64(1)}}
	opts := options.FindOneAndUpdate().
		SetUpsert(true).
		SetReturnDocument(options.After)

	var doc struct {
		Seq int64 `bson:"seq"`
	}
	if err := a.counters.FindOneAndUpdate(ctx, filter, update, opts).Decode(&doc); err != nil {
		return 0, func() {}, err
	}

	a.inFlight[doc.Seq] = struct{}{}

	var once sync.Once
	release := func() {
		once.Do(func() {
			a.mu.Lock()
			defer a.mu.Unlock()
			delete(a.inFlight, doc.Seq)
		})
	}

	return doc.Seq, release, nil
}

// watermark reports the highest sequence value the delta feed may serve right
// now: one below the lowest allocated-but-unwritten value, or unbounded when
// nothing is in flight. Serving strictly at or below this can never skip a
// lower sequence that is still on its way to the database.
func (a *sequenceAllocator) watermark() int64 {
	a.mu.Lock()
	defer a.mu.Unlock()

	lowest := unboundedWatermark
	for seq := range a.inFlight {
		if seq < lowest {
			lowest = seq
		}
	}
	if lowest == unboundedWatermark {
		return unboundedWatermark
	}
	return lowest - 1
}

// withSequence allocates a sequence value, runs the write that stamps it, and
// only then releases it back to the watermark. Every write path that touches
// Seq goes through here rather than allocating by hand, so none of them can
// forget to hold the feed back while their write is still in flight.
func (g *GalleryProvider) withSequence(ctx context.Context, write func(seq int64) error) error {
	seq, release, err := g.sequences.allocate(ctx)
	if err != nil {
		return err
	}
	defer release()
	return write(seq)
}
