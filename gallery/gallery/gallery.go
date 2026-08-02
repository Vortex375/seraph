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
	"log/slog"
	"path"
	"strings"
	"sync"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/fx"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/spaces/spaces"
	"umbasa.net/seraph/tracing"
	"umbasa.net/seraph/util"
)

const GallerySourceFolderCrudTopic = "seraph.gallery.sourcefolder.crud"

type Params struct {
	fx.In

	Nc      *nats.Conn
	Js      jetstream.JetStream `optional:"true"`
	Db      *mongo.Database
	Logger  *logging.Logger
	Tracing *tracing.Tracing
	Mig     Migrations
}

type Result struct {
	fx.Out

	GalleryProvider *GalleryProvider
}

type GalleryProvider struct {
	log     *slog.Logger
	tracer  trace.Tracer
	nc      *nats.Conn
	js      jetstream.JetStream
	logging *logging.Logger

	sourceFolders     *mongo.Collection
	photos            *mongo.Collection
	sequenceCounters  *mongo.Collection
	pendingTombstones *mongo.Collection

	crudSub  *nats.Subscription
	listSub  *nats.Subscription
	deltaSub *nats.Subscription

	// prefixCache and the durable file-change consumer implement event
	// ingestion; see ingest.go.
	prefixCache  *prefixCache
	ingest       *ingestConsumer
	ingestCancel context.CancelFunc
	wg           sync.WaitGroup

	// spacesChanged is the durable spaces.changed consumer that keeps
	// prefixCache invalidated when a Space's resolution changes underneath
	// it; see spaceschanged.go.
	spacesChanged       *spacesChangedConsumer
	spacesChangedCancel context.CancelFunc

	// backfillLimiter/backfillCtx bound and cancel backfill; see backfill.go.
	// backfillLimiter caps how many Gallery Source Folders are backfilled
	// concurrently (backfillParallel) so a burst of ADDs cannot turn into an
	// unbounded pile of goroutines competing with live ingestion and query
	// serving. backfillCtx is cancelled on Stop so an in-flight backfill
	// unblocks promptly instead of leaking past shutdown; g.wg (shared with
	// ingestion) is what Stop actually waits on to know every backfill
	// goroutine has exited.
	backfillLimiter util.Limiter
	backfillCtx     context.Context
	backfillCancel  context.CancelFunc
}

func New(p Params) (Result, error) {
	return Result{
		GalleryProvider: &GalleryProvider{
			log:               p.Logger.GetLogger("gallery"),
			tracer:            p.Tracing.TracerProvider.Tracer("gallery"),
			nc:                p.Nc,
			js:                p.Js,
			logging:           p.Logger,
			sourceFolders:     p.Db.Collection("gallerySourceFolders"),
			photos:            p.Db.Collection("galleryPhotos"),
			sequenceCounters:  p.Db.Collection("gallerySequenceCounters"),
			pendingTombstones: p.Db.Collection("galleryPendingTombstones"),
			prefixCache:       newPrefixCache(),
			backfillLimiter:   util.NewLimiter(backfillParallel),
		},
	}, nil
}

func (g *GalleryProvider) Start() error {
	sub, err := g.nc.QueueSubscribe(GallerySourceFolderCrudTopic, GallerySourceFolderCrudTopic, func(msg *nats.Msg) {
		ctx := messaging.ExtractTraceContext(context.Background(), msg)
		ctx, span := g.tracer.Start(ctx, "handleSourceFolderCrud")
		defer span.End()

		req := GallerySourceFolderCrudRequest{}
		json.Unmarshal(msg.Data, &req)

		resp := g.handleSourceFolderCrud(ctx, &req)

		data, _ := json.Marshal(resp)
		msg.Respond(data)
	})
	if err != nil {
		return fmt.Errorf("while starting GalleryProvider: %w", err)
	}
	g.crudSub = sub

	listSub, err := g.nc.QueueSubscribe(GalleryListTopic, GalleryListTopic, func(msg *nats.Msg) {
		ctx := messaging.ExtractTraceContext(context.Background(), msg)
		ctx, span := g.tracer.Start(ctx, "handleGalleryList")
		defer span.End()

		req := GalleryListRequest{}
		json.Unmarshal(msg.Data, &req)

		resp := g.listPhotos(ctx, &req)

		data, _ := json.Marshal(resp)
		msg.Respond(data)
	})
	if err != nil {
		return fmt.Errorf("while starting GalleryProvider: %w", err)
	}
	g.listSub = listSub

	deltaSub, err := g.nc.QueueSubscribe(GalleryDeltaTopic, GalleryDeltaTopic, func(msg *nats.Msg) {
		ctx := messaging.ExtractTraceContext(context.Background(), msg)
		ctx, span := g.tracer.Start(ctx, "handleGalleryDelta")
		defer span.End()

		req := GalleryDeltaRequest{}
		json.Unmarshal(msg.Data, &req)

		resp := g.deltaFeed(ctx, &req)

		data, _ := json.Marshal(resp)
		msg.Respond(data)
	})
	if err != nil {
		return fmt.Errorf("while starting GalleryProvider: %w", err)
	}
	g.deltaSub = deltaSub

	// build the prefix cache once at startup so ingestion can match events
	// cheaply from the first message; ADD/REMOVE keep it current afterwards
	// (see handleSourceFolderCrud), and the spaces.changed consumer started
	// below (see spaceschanged.go) keeps it current when a Space's
	// resolution changes underneath a folder rather than the folder set
	// itself changing.
	if err := g.refreshPrefixCache(context.Background()); err != nil {
		g.log.Error("failed to build initial gallery source folder prefix cache; ingestion will accept no events until it succeeds", "error", err)
	}

	ingestCtx, cancel := context.WithCancel(context.Background())
	g.ingestCancel = cancel
	ingest, err := g.startIngestConsumer(ingestCtx)
	if err != nil {
		g.log.Error("failed to start file-change ingestion; the gallery read model will not stay up to date", "error", err)
	} else {
		g.ingest = ingest
	}

	spacesChangedCtx, spacesChangedCancel := context.WithCancel(context.Background())
	g.spacesChangedCancel = spacesChangedCancel
	spacesChanged, err := g.startSpacesChangedConsumer(spacesChangedCtx)
	if err != nil {
		g.log.Error("failed to start spaces.changed consumer; the ingestion prefix cache will not invalidate on Space changes until restart", "error", err)
	} else {
		g.spacesChanged = spacesChanged
	}

	backfillCtx, backfillCancel := context.WithCancel(context.Background())
	g.backfillCtx = backfillCtx
	g.backfillCancel = backfillCancel

	// resume/restart any Gallery Source Folder backfill that had not
	// finished when the service last stopped. Runs in the background like
	// every other backfill (see startBackfill/runBackfill) so Start()
	// returns promptly regardless of how many folders are still pending.
	g.wg.Add(1)
	go func() {
		defer g.wg.Done()
		if err := g.resumeIncompleteBackfills(backfillCtx); err != nil {
			g.log.Error("failed to resume incomplete gallery source folder backfills", "error", err)
		}
	}()

	return nil
}

func (g *GalleryProvider) Stop() error {
	if g.crudSub != nil {
		err := g.crudSub.Unsubscribe()
		g.crudSub = nil
		if err != nil {
			return fmt.Errorf("while stopping GalleryProvider: %w", err)
		}
	}
	if g.listSub != nil {
		err := g.listSub.Unsubscribe()
		g.listSub = nil
		if err != nil {
			return fmt.Errorf("while stopping GalleryProvider: %w", err)
		}
	}
	if g.deltaSub != nil {
		err := g.deltaSub.Unsubscribe()
		g.deltaSub = nil
		if err != nil {
			return fmt.Errorf("while stopping GalleryProvider: %w", err)
		}
	}
	if g.ingest != nil {
		g.ingest.stop()
		g.ingest = nil
	}
	if g.ingestCancel != nil {
		g.ingestCancel()
		g.ingestCancel = nil
	}
	if g.spacesChanged != nil {
		g.spacesChanged.stop()
		g.spacesChanged = nil
	}
	if g.spacesChangedCancel != nil {
		g.spacesChangedCancel()
		g.spacesChangedCancel = nil
	}
	if g.backfillCancel != nil {
		g.backfillCancel()
		g.backfillCancel = nil
	}
	g.wg.Wait()
	return nil
}

func (g *GalleryProvider) handleSourceFolderCrud(ctx context.Context, req *GallerySourceFolderCrudRequest) *GallerySourceFolderCrudResponse {
	// every operation is scoped to a single user: one user's Gallery Source
	// Folders are never visible or modifiable by another
	if req.UserId == "" {
		return &GallerySourceFolderCrudResponse{
			Error: "userId is required",
		}
	}

	switch req.Operation {

	case GallerySourceFolderOperationList:
		return g.listSourceFolders(ctx, req)

	case GallerySourceFolderOperationAdd:
		return g.addSourceFolder(ctx, req)

	case GallerySourceFolderOperationRemove:
		return g.removeSourceFolder(ctx, req)

	default:
		return &GallerySourceFolderCrudResponse{
			Error: "invalid operation: " + req.Operation,
		}
	}
}

func (g *GalleryProvider) listSourceFolders(ctx context.Context, req *GallerySourceFolderCrudRequest) *GallerySourceFolderCrudResponse {
	result, err := g.sourceFolders.Find(ctx, bson.M{"userId": req.UserId})
	if err != nil {
		return &GallerySourceFolderCrudResponse{
			Error: err.Error(),
		}
	}

	folders := make([]GallerySourceFolder, 0)
	if err := result.All(ctx, &folders); err != nil {
		return &GallerySourceFolderCrudResponse{
			Error: err.Error(),
		}
	}

	return &GallerySourceFolderCrudResponse{
		SourceFolder: folders,
	}
}

func (g *GalleryProvider) addSourceFolder(ctx context.Context, req *GallerySourceFolderCrudRequest) *GallerySourceFolderCrudResponse {
	if req.SpaceProviderId == "" {
		return &GallerySourceFolderCrudResponse{
			Error: "spaceProviderId is required for ADD operation",
		}
	}

	folderPath, err := normalizePath(req.Path)
	if err != nil {
		return &GallerySourceFolderCrudResponse{
			Error: err.Error(),
		}
	}

	// refuse folders the user has no access to: resolving the space for this
	// user is the access check, and it is the same one the query path will
	// perform later
	if err := g.checkAccess(ctx, req.UserId, req.SpaceProviderId); err != nil {
		g.log.Warn("refusing to add Gallery Source Folder",
			"error", err, "userId", req.UserId, "spaceProviderId", req.SpaceProviderId, "path", folderPath)
		return &GallerySourceFolderCrudResponse{
			Error: err.Error(),
		}
	}

	// adding the same folder twice is idempotent rather than producing a
	// duplicate: upsert on the unique key, never insert
	filter := bson.M{
		"userId":          req.UserId,
		"spaceProviderId": req.SpaceProviderId,
		"path":            folderPath,
	}
	update := bson.M{
		"$setOnInsert": bson.M{
			"_id":             primitive.NewObjectID(),
			"userId":          req.UserId,
			"spaceProviderId": req.SpaceProviderId,
			"path":            folderPath,
		},
	}

	result := g.sourceFolders.FindOneAndUpdate(ctx, filter, update,
		options.FindOneAndUpdate().SetUpsert(true).SetReturnDocument(options.After))
	if result.Err() != nil {
		return &GallerySourceFolderCrudResponse{
			Error: result.Err().Error(),
		}
	}

	folder := GallerySourceFolder{}
	if err := result.Decode(&folder); err != nil {
		return &GallerySourceFolderCrudResponse{
			Error: err.Error(),
		}
	}

	// keep the ingestion prefix cache current so events under the newly
	// added folder start matching without a restart. Best-effort: a failure
	// here does not fail the ADD - the periodic/backfill paths are not this
	// ticket's concern, and the next successful CRUD op will retry the
	// refresh.
	if err := g.refreshPrefixCache(ctx); err != nil {
		g.log.Error("failed to refresh gallery source folder prefix cache after ADD", "error", err)
	}

	// backfill already-indexed photos under this folder in the background -
	// see backfill.go. ADD must return promptly, so this only resolves the
	// folder's physical prefix (one more SpaceResolveRequest, already paid
	// for access-checking above the resolution result isn't reused because
	// checkAccess deliberately reports only yes/no, not the resolved
	// prefix) and hands off to a goroutine; it never itself queries the File
	// Index. Safe to call for an idempotent re-ADD of an already-backfilled
	// folder too: runBackfill's BackfillDone check makes that a no-op rather
	// than a redundant rescan.
	//
	// The same resolution also feeds two more things: caching the physical
	// prefix onto the folder document (PhysicalProviderId/PhysicalPath - see
	// their docs on GallerySourceFolder) so a later REMOVE can scope its own
	// best-effort tombstone sweep without resolving again, and bumping the
	// delta sequence of every already-ingested photo newly covered by this
	// folder in the background, so an addition surfaces through the delta
	// feed without the client needing to know a folder was added - see
	// bumpSeqForPrefix's docs (delta.go). Both run independently of backfill
	// and are safe to interleave with it, since bumpSeqForPrefix only ever
	// touches Seq and never the rest of the document.
	if p, ok := g.resolveFolderPrefix(ctx, folder); ok {
		if err := g.cachePhysicalPrefix(ctx, folder.Id, p); err != nil {
			g.log.Error("failed to cache resolved physical prefix on gallery source folder", "error", err, "folderId", folder.Id.Hex())
		}
		g.startBackfill(folder.Id, p)
		g.startSeqBump(p)
	}

	return &GallerySourceFolderCrudResponse{
		SourceFolder: []GallerySourceFolder{folder},
	}
}

// cachePhysicalPrefix persists a folder's freshly resolved physical prefix
// onto its gallerySourceFolders document - see PhysicalProviderId/
// PhysicalPath's docs for why (REMOVE needs it and must not resolve again).
func (g *GalleryProvider) cachePhysicalPrefix(ctx context.Context, folderId primitive.ObjectID, p prefix) error {
	update := bson.M{"$set": bson.M{
		"physicalProviderId": p.providerId,
		"physicalPath":       p.path,
	}}
	_, err := g.sourceFolders.UpdateByID(ctx, folderId, update)
	return err
}

// removeSourceFolder removes a Gallery Source Folder from the user's
// configuration. It deletes a configuration document and nothing else: no file
// is deleted and no File Provider is contacted.
func (g *GalleryProvider) removeSourceFolder(ctx context.Context, req *GallerySourceFolderCrudRequest) *GallerySourceFolderCrudResponse {
	if req.Id == "" {
		return &GallerySourceFolderCrudResponse{
			Error: "id is required for REMOVE operation",
		}
	}

	id, err := primitive.ObjectIDFromHex(req.Id)
	if err != nil {
		return &GallerySourceFolderCrudResponse{
			Error: fmt.Errorf("invalid id: %w", err).Error(),
		}
	}

	// the userId filter is what stops a user removing another user's folder by
	// guessing its id
	filter := bson.M{
		"_id":    id,
		"userId": req.UserId,
	}

	result := g.sourceFolders.FindOneAndDelete(ctx, filter)
	if errors.Is(result.Err(), mongo.ErrNoDocuments) {
		return &GallerySourceFolderCrudResponse{
			Error: "no such gallery source folder: " + req.Id,
		}
	}
	if result.Err() != nil {
		return &GallerySourceFolderCrudResponse{
			Error: result.Err().Error(),
		}
	}

	folder := GallerySourceFolder{}
	if err := result.Decode(&folder); err != nil {
		return &GallerySourceFolderCrudResponse{
			Error: err.Error(),
		}
	}

	// Deliberately does NOT refresh the prefix cache here (unlike ADD): doing
	// so would issue a SpaceResolveRequest for every other configured
	// folder, contradicting the documented, tested contract above that
	// REMOVE "deletes a configuration document and nothing else" - see
	// TestRemoveTouchesNoFileProvider. A stale prefix for the just-removed
	// folder is harmless: the read model it feeds is shared infrastructure
	// (see package docs), access control is enforced per-user at query
	// time, and the next ADD anywhere naturally refreshes the whole cache.
	//
	// The tombstone sweep below is the one exception to "touches nothing
	// else" worth calling out explicitly: it reads the physical prefix
	// cached on the just-deleted document itself (see PhysicalProviderId/
	// PhysicalPath's docs) rather than resolving anything, so it costs a
	// local Mongo scan/write over this service's own read model and nothing
	// more - no NATS request to any other service, so
	// TestRemoveTouchesNoFileProvider still holds. It is what makes a REMOVE
	// eventually surface as tombstones in the delta feed (see
	// recordRemovalTombstones's docs in delta.go) rather than leaving the
	// removed folder's photos permanently, silently visible to a mirror. A
	// folder that was never successfully resolved (PhysicalProviderId empty
	// - e.g. it never had access) has nothing to sweep, which is correct: it
	// never made anything visible in the first place.
	if folder.PhysicalProviderId != "" {
		removedFolder := resolvedFolder{
			providerId:      folder.PhysicalProviderId,
			path:            folder.PhysicalPath,
			spaceProviderId: folder.SpaceProviderId,
			spacePath:       folder.Path,
		}
		g.startRemovalTombstoneSweep(folder.UserId, removedFolder)
	}

	return &GallerySourceFolderCrudResponse{
		SourceFolder: []GallerySourceFolder{folder},
	}
}

// checkAccess verifies that the given user may use the given space provider, by
// resolving it for that user. An empty resolve response means the space does not
// exist or is not assigned to the user; either way the folder must be refused.
func (g *GalleryProvider) checkAccess(ctx context.Context, userId string, spaceProviderId string) error {
	res, err := g.resolveSpace(ctx, spaces.SpaceResolveRequest{
		UserId:          userId,
		SpaceProviderId: spaceProviderId,
	})
	if err != nil {
		return fmt.Errorf("unable to resolve space %s for user %s: %w", spaceProviderId, userId, err)
	}
	if res.Error != "" {
		return fmt.Errorf("unable to resolve space %s for user %s: %w", spaceProviderId, userId, errors.New(res.Error))
	}
	if res.ProviderId == "" {
		return errors.New("no access to space: " + spaceProviderId)
	}

	return nil
}

// resolveSpace is the single place that issues a spaces.SpaceResolveRequest
// over NATS. checkAccess (the ADD access check), refreshPrefixCache (the
// ingestion prefix cache), resolveFoldersForUser (the query-time access
// check) and backfill's resolveFolderPrefix all resolve a Gallery Source
// Folder's Space coordinates to a physical (providerId, path); they differ
// only in what they do with the result and how they react to a failure, not
// in how the request is built or sent - so that part lives here once.
func (g *GalleryProvider) resolveSpace(ctx context.Context, req spaces.SpaceResolveRequest) (spaces.SpaceResolveResponse, error) {
	res := spaces.SpaceResolveResponse{}
	err := messaging.Request(ctx, g.nc, spaces.SpaceResolveTopic, messaging.Json(&req), messaging.Json(&res))
	return res, err
}

// spacesResolveRequest builds the SpaceResolveRequest for one Gallery Source
// Folder - the same (UserId, SpaceProviderId) pair every resolution call
// site (checkAccess, refreshPrefixCache, resolveFoldersForUser, backfill)
// sends, extracted so backfill does not need to know the request shape
// beyond "give me a folder".
func spacesResolveRequest(f GallerySourceFolder) spaces.SpaceResolveRequest {
	return spaces.SpaceResolveRequest{
		UserId:          f.UserId,
		SpaceProviderId: f.SpaceProviderId,
	}
}

// joinPhysicalPath joins a resolved Space's physical root (SpaceResolveResponse.Path)
// with a Gallery Source Folder's Space-relative Path into the physical path
// to query/match against, normalizing an empty join to "/" exactly like
// refreshPrefixCache and resolveFoldersForUser already do inline.
func joinPhysicalPath(spaceRootPath string, folderPath string) string {
	p := path.Join(spaceRootPath, folderPath)
	if p == "" {
		p = "/"
	}
	return p
}

// normalizePath brings a user-picked path into a canonical form so that the
// same folder picked twice - with or without a trailing slash - is recognised
// as the same folder.
func normalizePath(p string) (string, error) {
	if p == "" {
		p = "/"
	}
	if !strings.HasPrefix(p, "/") {
		return "", errors.New("path must start with '/'")
	}
	return path.Clean(p), nil
}
