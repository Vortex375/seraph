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

package shares

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"path"
	"strings"

	"github.com/nats-io/nats.go"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/fx"
	"umbasa.net/seraph/entities"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/tracing"
)

const ShareResolveTopic = "seraph.shares.resolve"
const ShareCrudTopic = "seraph.shares.crud"

type Params struct {
	fx.In

	Nc      *nats.Conn
	Db      *mongo.Database
	Logger  *logging.Logger
	Tracing *tracing.Tracing
	Mig     Migrations
}

type Result struct {
	fx.Out

	SharesProvider *SharesProvider
}

type SharesProvider struct {
	log        *slog.Logger
	tracer     trace.Tracer
	nc         *nats.Conn
	shares     *mongo.Collection
	resolveSub *nats.Subscription
	crudSub    *nats.Subscription
}

func New(p Params) (Result, error) {
	return Result{
		SharesProvider: &SharesProvider{
			log:    p.Logger.GetLogger("shares"),
			tracer: p.Tracing.TracerProvider.Tracer("shares"),
			nc:     p.Nc,
			shares: p.Db.Collection("shares"),
		},
	}, nil
}

func (s *SharesProvider) Start() error {
	sub, err := s.nc.QueueSubscribe(ShareResolveTopic, ShareResolveTopic, func(msg *nats.Msg) {
		ctx := messaging.ExtractTraceContext(context.Background(), msg)
		ctx, span := s.tracer.Start(ctx, "resolveShare")
		defer span.End()

		req := ShareResolveRequest{}
		json.Unmarshal(msg.Data, &req)

		resp := s.resolveShare(ctx, &req)

		data, _ := json.Marshal(resp)
		msg.Respond(data)
	})
	if err != nil {
		return fmt.Errorf("While starting SharesProvider: %w", err)
	}
	s.resolveSub = sub
	sub, err = s.nc.QueueSubscribe(ShareCrudTopic, ShareCrudTopic, func(msg *nats.Msg) {
		ctx := messaging.ExtractTraceContext(context.Background(), msg)
		ctx, span := s.tracer.Start(ctx, "handleCrud")
		defer span.End()

		req := ShareCrudRequest{
			Share: entities.MakePrototype(&SharePrototype{}),
		}
		json.Unmarshal(msg.Data, &req)

		resp := s.handleCrud(ctx, &req)

		data, _ := json.Marshal(resp)
		msg.Respond(data)
	})
	if err != nil {
		return fmt.Errorf("While starting SharesProvider: %w", err)
	}
	s.crudSub = sub
	return nil
}

func (s *SharesProvider) Stop() error {
	var err error
	if s.crudSub != nil {
		err = s.crudSub.Unsubscribe()
		s.crudSub = nil
	}
	if err != nil {
		return fmt.Errorf("While stopping SharesProvider: %w", err)
	}
	if s.resolveSub != nil {
		err = s.resolveSub.Unsubscribe()
		s.resolveSub = nil
	}
	if err != nil {
		return fmt.Errorf("While stopping SharesProvider: %w", err)
	}
	return nil
}

func (s *SharesProvider) resolveShare(ctx context.Context, req *ShareResolveRequest) *ShareResolveResponse {
	filter := SharePrototype{}
	filter.ShareID.Set(req.ShareID)

	result := s.shares.FindOne(ctx, filter)
	if result.Err() != nil {
		if errors.Is(result.Err(), mongo.ErrNoDocuments) {
			// empty response indicates "not found"
			return &ShareResolveResponse{}
		}
		err := fmt.Errorf("While retrieving share from the database for resolve: %w", result.Err())
		s.log.Error("error while resolving share", "error", err)
		return &ShareResolveResponse{
			Error: result.Err().Error(),
		}
	}
	share := Share{}
	result.Decode(&share)

	var cleanPath string
	if req.Path != "" {
		if !share.IsDir {
			return &ShareResolveResponse{}
		}
		cleanPath = strings.TrimPrefix(path.Clean("/"+req.Path), "/")
		if strings.Contains(cleanPath, "/") && !share.Recursive {
			return &ShareResolveResponse{}
		}
	}

	resolvedPath := path.Join(share.Path, cleanPath)

	//TODO: check if owner has access

	return &ShareResolveResponse{
		ProviderID: share.ProviderID,
		Path:       resolvedPath,
	}
}

func (s *SharesProvider) handleCrud(ctx context.Context, req *ShareCrudRequest) *ShareCrudResponse {
	switch req.Operation {

	case "READ":
		if !req.Share.ShareID.IsDefined() && !req.Share.Owner.IsDefined() {
			return &ShareCrudResponse{
				Error: "shareID or owner is required for READ operation",
			}
		}
		result, err := s.shares.Find(ctx, req.Share)
		if err != nil {
			return &ShareCrudResponse{
				Error: err.Error(),
			}
		}

		shares := make([]Share, 0)
		for result.Next(ctx) {
			share := Share{}
			result.Decode(&share)
			shares = append(shares, share)
		}
		if result.Err() != nil {
			return &ShareCrudResponse{
				Error: result.Err().Error(),
			}
		}

		return &ShareCrudResponse{
			Share: shares,
		}

	case "CREATE":

		if !req.Share.ShareID.IsDefined() {
			return &ShareCrudResponse{
				Error: "shareID is required for CREATE operation",
			}
		}
		insertRes, err := s.shares.InsertOne(ctx, req.Share)

		if err != nil {
			return &ShareCrudResponse{
				Error: err.Error(),
			}
		}

		findRes := s.shares.FindOne(ctx, bson.M{"_id": insertRes.InsertedID})

		share := Share{}
		findRes.Decode(&share)

		return &ShareCrudResponse{
			Share: []Share{share},
		}

	case "UPDATE":

		if !req.Share.ShareID.IsDefined() {
			return &ShareCrudResponse{
				Error: "shareID is required for UPDATE operation",
			}
		}

		filter := SharePrototype{}
		filter.ShareID.Set(req.Share.ShareID.Get())
		if filter.Owner.IsDefined() {
			filter.Owner.Set(req.Share.Owner.Get())
		}
		result := s.shares.FindOneAndUpdate(ctx, filter, bson.M{"$set": req.Share},
			options.FindOneAndUpdate().SetReturnDocument(options.After))
		if result.Err() != nil {
			return &ShareCrudResponse{
				Error: result.Err().Error(),
			}
		}

		share := Share{}
		result.Decode(&share)

		return &ShareCrudResponse{
			Share: []Share{share},
		}

	case "DELETE":

		if !req.Share.ShareID.IsDefined() {
			return &ShareCrudResponse{
				Error: "shareID is required for DELETE operation",
			}
		}

		result := s.shares.FindOneAndDelete(ctx, req.Share)
		if result.Err() != nil {
			return &ShareCrudResponse{
				Error: result.Err().Error(),
			}
		}

		share := Share{}
		result.Decode(&share)

		return &ShareCrudResponse{
			Share: []Share{share},
		}

	default:
		return &ShareCrudResponse{
			Error: "invalid CRUD operation: " + req.Operation,
		}
	}
}
