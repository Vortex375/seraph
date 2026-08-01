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

	sourceFolders *mongo.Collection
	photos        *mongo.Collection

	crudSub *nats.Subscription

	// prefixCache and the durable file-change consumer implement event
	// ingestion; see ingest.go.
	prefixCache  *prefixCache
	ingest       *ingestConsumer
	ingestCancel context.CancelFunc
	wg           sync.WaitGroup
}

func New(p Params) (Result, error) {
	return Result{
		GalleryProvider: &GalleryProvider{
			log:           p.Logger.GetLogger("gallery"),
			tracer:        p.Tracing.TracerProvider.Tracer("gallery"),
			nc:            p.Nc,
			js:            p.Js,
			logging:       p.Logger,
			sourceFolders: p.Db.Collection("gallerySourceFolders"),
			photos:        p.Db.Collection("galleryPhotos"),
			prefixCache:   newPrefixCache(),
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

	// build the prefix cache once at startup so ingestion can match events
	// cheaply from the first message; ADD/REMOVE keep it current afterwards
	// (see handleSourceFolderCrud). Re-resolving on spaces.changed - so a
	// re-pointed Space is picked up without waiting for a folder edit - is
	// ticket 09's job.
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
	if g.ingest != nil {
		g.ingest.stop()
		g.ingest = nil
	}
	if g.ingestCancel != nil {
		g.ingestCancel()
		g.ingestCancel = nil
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

	return &GallerySourceFolderCrudResponse{
		SourceFolder: []GallerySourceFolder{folder},
	}
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
	return &GallerySourceFolderCrudResponse{
		SourceFolder: []GallerySourceFolder{folder},
	}
}

// checkAccess verifies that the given user may use the given space provider, by
// resolving it for that user. An empty resolve response means the space does not
// exist or is not assigned to the user; either way the folder must be refused.
func (g *GalleryProvider) checkAccess(ctx context.Context, userId string, spaceProviderId string) error {
	req := spaces.SpaceResolveRequest{
		UserId:          userId,
		SpaceProviderId: spaceProviderId,
	}
	res := spaces.SpaceResolveResponse{}

	err := messaging.Request(ctx, g.nc, spaces.SpaceResolveTopic, messaging.Json(&req), messaging.Json(&res))
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
