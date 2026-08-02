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
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/nats-io/nats.go/jetstream"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo/options"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/util"
)

// ingestConsumerName is the durable JetStream consumer name the gallery
// service uses on events.FileChangedStream. Fixed and well-known, like the
// thumbnailer's invalidation consumer, so the delivery position survives
// restarts: a durable that isn't recreated under the same name starts over
// from the beginning of the stream.
const ingestConsumerName = "SERAPH_GALLERY_INGEST"

// ingestParallel bounds how many file-change events are processed
// concurrently. Metadata extraction reads the full file over NATS
// request/reply and decodes it, so this is deliberately modest - this is
// background ingestion, not an interactive request.
const ingestParallel = 4

// prefix is a resolved physical location a Gallery Source Folder currently
// points at: every event under providerId+path (as a path prefix) belongs to
// at least one configured folder.
type prefix struct {
	providerId string
	path       string // cleaned, no trailing slash except root "/"
}

// contains reports whether p is a prefix of (or equal to) candidatePath on
// the same provider. Comparison is prefix-of-path-segments, not
// string-prefix, so a folder named "/Photos2" does not match a configured
// folder "/Photos".
func (p prefix) contains(providerId string, candidatePath string) bool {
	if p.providerId != providerId {
		return false
	}
	if p.path == "/" {
		return true
	}
	if candidatePath == p.path {
		return true
	}
	return strings.HasPrefix(candidatePath, p.path+"/")
}

// prefixCache is the cheap-matching structure event ingestion filters
// against: the resolved physical prefixes of every configured Gallery Source
// Folder, across all users. Resolution (a SpaceResolveRequest per configured
// folder) happens when the cache is (re)built, never per event - that is the
// whole point of caching it.
//
// The cache is rebuilt on startup, on ADD (see handleSourceFolderCrud), and
// on a relevant spaces.changed event (see spaceschanged.go) - so a Space
// re-pointed at a different File Provider, one that becomes inaccessible, or
// one that is deleted is all picked up without a restart. refresh() (see
// refreshPrefixCache below) is the seam every one of those call sites shares.
type prefixCache struct {
	mu       sync.RWMutex
	prefixes []prefix
}

func newPrefixCache() *prefixCache {
	return &prefixCache{}
}

func (c *prefixCache) set(prefixes []prefix) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.prefixes = prefixes
}

// matches reports whether the given physical (providerId, path) falls under
// any cached prefix. O(number of configured folders), with no network call -
// this is what keeps per-event filtering cheap.
func (c *prefixCache) matches(providerId string, filePath string) bool {
	c.mu.RLock()
	defer c.mu.RUnlock()
	for _, p := range c.prefixes {
		if p.contains(providerId, filePath) {
			return true
		}
	}
	return false
}

// refresh re-resolves every configured Gallery Source Folder (across all
// users - the cache is not per-user, see package docs) and replaces the
// cached prefix set. A folder whose Space no longer resolves for its owner
// (access revoked, Space deleted) is simply dropped from the cache: its
// events stop matching, which is exactly the access-control behaviour the
// query path also relies on.
//
// It also persists each successfully resolved prefix back onto its folder
// document (PhysicalProviderId/PhysicalPath - see cachePhysicalPrefix). That
// matters because this function is the single seam every resolution trigger
// shares - startup, ADD, and a relevant spaces.changed event (see
// reactToSpaceChanged) - so an administrator re-pointing a Space at a
// different File Provider updates the persisted prefix here too, not just
// the in-memory ingestion cache. Without that, a folder REMOVEd after a
// re-point would sweep tombstones against the OLD physical prefix and a
// mirror would keep showing photos that had actually gone away.
//
// A folder that fails to resolve keeps its last persisted prefix rather than
// having it cleared: an unresolvable folder is usually a transient or
// access-related condition, and the stale-but-real prefix is strictly better
// than nothing for a later REMOVE sweep, which is the only thing that reads
// it.
func (g *GalleryProvider) refreshPrefixCache(ctx context.Context) error {
	cur, err := g.sourceFolders.Find(ctx, bson.M{})
	if err != nil {
		return fmt.Errorf("while listing gallery source folders: %w", err)
	}

	folders := make([]GallerySourceFolder, 0)
	if err := cur.All(ctx, &folders); err != nil {
		return fmt.Errorf("while listing gallery source folders: %w", err)
	}

	seen := make(map[prefix]bool)
	prefixes := make([]prefix, 0, len(folders))
	for _, f := range folders {
		res, err := g.resolveSpace(ctx, spacesResolveRequest(f))
		if err != nil {
			g.log.Warn("failed to resolve gallery source folder; excluding it from ingestion until it resolves",
				"error", err, "userId", f.UserId, "spaceProviderId", f.SpaceProviderId, "path", f.Path)
			continue
		}
		if res.Error != "" || res.ProviderId == "" {
			g.log.Warn("gallery source folder does not resolve; excluding it from ingestion",
				"error", res.Error, "userId", f.UserId, "spaceProviderId", f.SpaceProviderId, "path", f.Path)
			continue
		}

		p := prefix{providerId: res.ProviderId, path: joinPhysicalPath(res.Path, f.Path)}

		// keep the folder's persisted physical prefix in step with what it
		// actually resolves to right now - see this function's docs and
		// GallerySourceFolder.PhysicalProviderId/PhysicalPath
		if f.PhysicalProviderId != p.providerId || f.PhysicalPath != p.path {
			if err := g.cachePhysicalPrefix(ctx, f.Id, p); err != nil {
				g.log.Error("failed to update persisted physical prefix for gallery source folder",
					"error", err, "folderId", f.Id.Hex(), "userId", f.UserId, "spaceProviderId", f.SpaceProviderId)
			}
		}

		if !seen[p] {
			seen[p] = true
			prefixes = append(prefixes, p)
		}
	}

	g.prefixCache.set(prefixes)
	g.log.Debug("refreshed gallery source folder prefix cache", "count", len(prefixes))
	return nil
}

// startIngestConsumer creates (or reattaches to) the durable file-change
// consumer and begins ingesting FileChangedEvent messages in the background.
func (g *GalleryProvider) startIngestConsumer(ctx context.Context) (*ingestConsumer, error) {
	if g.js == nil {
		return nil, nil
	}

	streamCtx := context.Background()

	stream, err := g.js.CreateOrUpdateStream(streamCtx, jetstream.StreamConfig{
		Name:     events.FileChangedStream,
		Subjects: []string{events.FileChangedTopic},
	})
	if err != nil {
		return nil, fmt.Errorf("create/update %s stream: %w", events.FileChangedStream, err)
	}

	cons, err := stream.CreateOrUpdateConsumer(streamCtx, jetstream.ConsumerConfig{
		Durable:   ingestConsumerName,
		AckPolicy: jetstream.AckExplicitPolicy,
	})
	if err != nil {
		return nil, fmt.Errorf("create/update %s consumer: %w", ingestConsumerName, err)
	}

	iter, err := cons.Messages()
	if err != nil {
		return nil, fmt.Errorf("start consuming %s: %w", ingestConsumerName, err)
	}

	ic := &ingestConsumer{
		g:       g,
		iter:    iter,
		limiter: util.NewLimiter(ingestParallel),
	}

	g.wg.Add(1)
	go ic.loop(ctx, &g.wg)

	return ic, nil
}

type ingestConsumer struct {
	g       *GalleryProvider
	iter    jetstream.MessagesContext
	limiter util.Limiter
}

func (ic *ingestConsumer) stop() {
	if ic == nil {
		return
	}
	ic.iter.Stop()
}

func (ic *ingestConsumer) loop(ctx context.Context, wg *sync.WaitGroup) {
	defer wg.Done()

	for {
		msg, err := ic.iter.Next()
		if errors.Is(err, jetstream.ErrMsgIteratorClosed) {
			return
		}
		if err != nil {
			ic.g.log.Error("file-change consumer error", "error", err)
			return
		}

		if !ic.limiter.Begin(ctx) {
			return
		}

		ic.g.wg.Add(1)
		go func() {
			defer ic.g.wg.Done()
			defer ic.limiter.End()
			ic.handleMessage(ctx, msg)
		}()
	}
}

func (ic *ingestConsumer) handleMessage(ctx context.Context, msg jetstream.Msg) {
	g := ic.g

	ev := events.FileChangedEvent{}
	if err := ev.Unmarshal(msg.Data()); err != nil {
		g.log.Error("failed to deserialize FileChangedEvent", "error", err)
		// malformed payload will never parse on redelivery either
		msg.Ack()
		return
	}

	if ev.IsDir {
		// the gallery only ever holds files
		msg.Ack()
		return
	}

	// cheap reject: no resolve, just a prefix-set lookup
	if !g.prefixCache.matches(ev.ProviderID, ev.Path) {
		msg.Ack()
		return
	}

	ctx, span := g.tracer.Start(ctx, "handleFileChanged")
	defer span.End()

	var err error
	switch ev.Change {
	case events.FileChangedEventDeleted:
		err = g.markDeleted(ctx, ev.ProviderID, ev.Path)
	case events.FileChangedEventCreated, events.FileChangedEventChanged:
		err = g.upsertPhoto(ctx, &ev)
	default:
		// unknown change kind: nothing to do, but ack so it doesn't block
		// the stream forever
	}

	if err != nil {
		g.log.Error("failed to process file-change event for gallery", "provider", ev.ProviderID, "path", ev.Path, "change", ev.Change, "error", err)
		// leave unacked so JetStream redelivers; the handler is idempotent
		// (upsert on the physical key), so redelivery is safe. This is also
		// how a corrupt/truncated file for ONE item is prevented from
		// stalling ingestion for the rest of the folder: every other event
		// keeps being acked and processed independently.
		return
	}

	msg.Ack()
}

// markDeleted removes a photo from the listing in response to a "deleted"
// file-change event. The document is flagged rather than physically removed:
// a later re-creation at the same path is then an ordinary upsert.
//
// This is also the delta feed's tombstone write: bumping Seq on the same
// update that sets Deleted is what makes the deletion show up as a changed
// row the next time a client polls past this point (see delta.go) - a mirror
// sees a tombstone for the item and removes it locally, rather than the
// document silently vanishing from a query it can no longer distinguish from
// "never existed".
func (g *GalleryProvider) markDeleted(ctx context.Context, providerId string, filePath string) error {
	return g.withSequence(ctx, func(seq int64) error {
		filter := bson.M{"providerId": providerId, "path": filePath}
		update := bson.M{"$set": bson.M{"deleted": true, "seq": seq}}
		_, err := g.photos.UpdateOne(ctx, filter, update)
		return err
	})
}

// upsertPhoto extracts metadata for a created/changed file and writes it
// into the read model, upserted on the physical key (providerId, path) so
// the same file arriving twice - by two live events, or later by backfill -
// produces exactly one document.
//
// This is the live-event path, so it always performs full byte-level
// extraction and always writes metadataPending: false - even if a prior
// backfill page had already written a MetadataPending placeholder for this
// same physical key. A live event carries strictly better information than
// backfill ever can (see backfill.go's package docs on the metadata
// tension), so it unconditionally wins and heals the placeholder, regardless
// of which of the two arrived first.
func (g *GalleryProvider) upsertPhoto(ctx context.Context, ev *events.FileChangedEvent) error {
	meta, capturedAt, capturedAtSource, err := g.extractForEvent(ctx, ev)
	if err != nil {
		return err
	}

	now := time.Now().Unix()

	err = g.withSequence(ctx, func(seq int64) error {
		filter := bson.M{"providerId": ev.ProviderID, "path": ev.Path}
		update := bson.M{
			"$set": bson.M{
				"providerId":       ev.ProviderID,
				"path":             ev.Path,
				"capturedAt":       capturedAt,
				"capturedAtSource": capturedAtSource,
				"width":            meta.Width,
				"height":           meta.Height,
				"orientation":      meta.Orientation,
				"size":             ev.Size,
				"mime":             ev.Mime,
				"unsupported":      meta.Unsupported,
				"deleted":          false,
				"metadataPending":  false,
				"seq":              seq,
			},
			// IndexedAt/CapturedAt-when-falling-back-to-indexed must only be
			// set on first insert: a later re-processing of the same file (a
			// "changed" event, or backfill racing a live event) must not move
			// an already-established "first seen" time.
			"$setOnInsert": bson.M{
				"indexedAt": now,
			},
		}

		_, err := g.photos.UpdateOne(ctx, filter, update, options.Update().SetUpsert(true))
		return err
	})
	if err != nil {
		return err
	}

	// dispatch background Thumbnail pre-generation now that this photo is in
	// the read model - fire-and-forget onto the durable warm work queue, not
	// the thumbnailer's interactive path (see dispatchThumbnailWarm's docs).
	// Skipped for a file already known undecodable: the thumbnailer would
	// only fail identically and there is nothing to warm.
	if meta.Unsupported == "" {
		g.dispatchThumbnailWarm(ctx, ev.ProviderID, ev.Path)
	}

	return nil
}

// extractForEvent fetches the file through the File Provider, extracts
// pixel/orientation metadata, and resolves Capture Date via the fallback
// chain EXIF DateTimeOriginal -> file modification time -> time first
// indexed.
//
// A file that cannot be opened at all (provider error, not a decode
// failure) is reported as an error so the caller leaves the event unacked
// for redelivery - that is a transient/infra failure, not "this file is not
// a supported photo".
func (g *GalleryProvider) extractForEvent(ctx context.Context, ev *events.FileChangedEvent) (photoMetadata, int64, string, error) {
	client := fileprovider.NewFileProviderClient(ev.ProviderID, g.nc, g.logging)
	defer client.Close()

	f, err := client.OpenFile(ctx, ev.Path, os.O_RDONLY, 0)
	if err != nil {
		return photoMetadata{}, 0, "", fmt.Errorf("opening %s/%s: %w", ev.ProviderID, ev.Path, err)
	}
	defer f.Close()

	buf, err := bufferAll(f)
	if err != nil {
		return photoMetadata{}, 0, "", fmt.Errorf("reading %s/%s: %w", ev.ProviderID, ev.Path, err)
	}

	meta := extractMetadata(buf)

	capturedAt, capturedAtSource := resolveCaptureDate(buf, ev)

	return meta, capturedAt, capturedAtSource, nil
}

// resolveCaptureDate implements the Capture Date fallback chain: EXIF
// DateTimeOriginal, then the file's modification time as carried by the
// file-change event, then the current time (this item's "first indexed"
// moment) if even that is unusable.
//
// Modification time is deliberately never treated as authoritative: it is
// only rung two of the chain, because cloud-side modification time is
// effectively upload time and cannot be used as an ordering key on its own
// (see FileChangedEvent.ModTime and the package docs).
//
// A photo whose EXIF date is nonsensical (implausible year, far future) is
// still accepted as-is at rung one - it is not rejected and does not fall
// through to a later rung. Only an absent or unparseable tag falls through.
// r is tried for EXIF regardless of meta.Unsupported: a file image/Decode
// cannot handle (e.g. a RAW format Go's stdlib doesn't register) may still
// carry a perfectly good EXIF header.
func resolveCaptureDate(r *bytes.Reader, ev *events.FileChangedEvent) (int64, string) {
	if _, err := r.Seek(0, io.SeekStart); err == nil {
		if t, ok := exifCaptureDate(r); ok {
			return t.Unix(), CaptureDateSourceExif
		}
	}

	if ev.ModTime != 0 {
		return ev.ModTime, CaptureDateSourceModTime
	}

	return time.Now().Unix(), CaptureDateSourceIndexed
}
