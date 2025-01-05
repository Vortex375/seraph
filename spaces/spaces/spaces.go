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

package spaces

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
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

const SpaceResolveTopic = "seraph.spaces.resolve"
const SpaceCrudTopic = "seraph.spaces.crud"

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

	SpacesProvider *SpacesProvider
}

type SpacesProvider struct {
	log        *slog.Logger
	tracer     trace.Tracer
	nc         *nats.Conn
	spaces     *mongo.Collection
	resolveSub *nats.Subscription
	crudSub    *nats.Subscription
}

func New(p Params) (Result, error) {
	return Result{
		SpacesProvider: &SpacesProvider{
			log:    p.Logger.GetLogger("spaces"),
			tracer: p.Tracing.TracerProvider.Tracer("spaces"),
			nc:     p.Nc,
			spaces: p.Db.Collection("spaces"),
		},
	}, nil
}

func (s *SpacesProvider) Start() error {
	sub, err := s.nc.QueueSubscribe(SpaceResolveTopic, SpaceResolveTopic, func(msg *nats.Msg) {
		ctx := messaging.ExtractTraceContext(context.Background(), msg)
		ctx, span := s.tracer.Start(ctx, "resolveSpace")
		defer span.End()

		req := SpaceResolveRequest{}
		json.Unmarshal(msg.Data, &req)

		resp := s.resolveSpace(ctx, &req)

		data, _ := json.Marshal(resp)
		msg.Respond(data)
	})
	if err != nil {
		return fmt.Errorf("While starting SpacesProvider: %w", err)
	}
	s.resolveSub = sub
	sub, err = s.nc.QueueSubscribe(SpaceCrudTopic, SpaceCrudTopic, func(msg *nats.Msg) {
		ctx := messaging.ExtractTraceContext(context.Background(), msg)
		ctx, span := s.tracer.Start(ctx, "handleCrud")
		defer span.End()

		req := SpaceCrudRequest{
			Space: entities.MakePrototype(&SpacePrototype{}),
		}
		json.Unmarshal(msg.Data, &req)

		resp := s.handleCrud(ctx, &req)

		data, _ := json.Marshal(resp)
		msg.Respond(data)
	})
	if err != nil {
		return fmt.Errorf("While starting SpacesProvider: %w", err)
	}
	s.crudSub = sub
	return nil
}

func (s *SpacesProvider) Stop() error {
	var err error
	if s.crudSub != nil {
		err = s.crudSub.Unsubscribe()
		s.crudSub = nil
	}
	if err != nil {
		return fmt.Errorf("While stopping SpacesProvider: %w", err)
	}
	if s.resolveSub != nil {
		err = s.resolveSub.Unsubscribe()
		s.resolveSub = nil
	}
	if err != nil {
		return fmt.Errorf("While stopping SpacesProvider: %w", err)
	}
	return nil
}

func (s *SpacesProvider) resolveSpace(ctx context.Context, req *SpaceResolveRequest) *SpaceResolveResponse {
	filter := bson.M{
		"users":                         req.UserId,
		"fileProviders.spaceProviderId": req.SpaceProviderId,
	}

	res := s.spaces.FindOne(ctx, filter)

	if errors.Is(res.Err(), mongo.ErrNoDocuments) {
		// empty response indicates "not found"
		return &SpaceResolveResponse{}
	}
	if res.Err() != nil {
		err := fmt.Errorf("While retrieving spaces from the database for resolve: %w", res.Err())
		s.log.Error("error while resolving space", "error", err)
		return &SpaceResolveResponse{
			Error: res.Err().Error(),
		}
	}
	space := Space{}
	res.Decode(&space)

	for _, provider := range space.FileProviders {
		if provider.SpaceProviderId == req.SpaceProviderId {
			return &SpaceResolveResponse{
				ProviderId: provider.ProviderId,
				Path:       provider.Path,
				ReadOnly:   provider.ReadOnly,
			}
		}
	}

	return &SpaceResolveResponse{}
}

func (s *SpacesProvider) handleCrud(ctx context.Context, req *SpaceCrudRequest) *SpaceCrudResponse {
	switch req.Operation {

	case "READ":

		filter := bson.M{}
		if req.Space.Id.IsDefined() {
			filter["_id"] = req.Space.Id.Get()
		}
		if req.Space.Users.IsDefined() {
			filter["users"] = bson.M{"$all": req.Space.Users.Get()}
		}

		result, err := s.spaces.Find(ctx, filter)
		if err != nil {
			return &SpaceCrudResponse{
				Error: err.Error(),
			}
		}

		spaces := make([]Space, 0)
		for result.Next(ctx) {
			space := Space{}
			result.Decode(&space)
			spaces = append(spaces, space)
		}
		if result.Err() != nil {
			return &SpaceCrudResponse{
				Error: result.Err().Error(),
			}
		}

		return &SpaceCrudResponse{
			Space: spaces,
		}

	case "CREATE":

		err := s.validateSpaceProviderUnique(ctx, req.Space)
		if err != nil {
			return &SpaceCrudResponse{
				Error: err.Error(),
			}
		}

		insertRes, err := s.spaces.InsertOne(ctx, req.Space)

		if err != nil {
			return &SpaceCrudResponse{
				Error: err.Error(),
			}
		}

		findRes := s.spaces.FindOne(ctx, bson.M{"_id": insertRes.InsertedID})

		space := Space{}
		findRes.Decode(&space)

		return &SpaceCrudResponse{
			Space: []Space{space},
		}

	case "UPDATE":

		if !req.Space.Id.IsDefined() {
			return &SpaceCrudResponse{
				Error: "id is required for UPDATE operation",
			}
		}

		err := s.validateSpaceProviderUnique(ctx, req.Space)
		if err != nil {
			return &SpaceCrudResponse{
				Error: err.Error(),
			}
		}

		filter := SpacePrototype{}
		filter.Id.Set(req.Space.Id.Get())
		result := s.spaces.FindOneAndUpdate(ctx, filter, bson.M{"$set": req.Space},
			options.FindOneAndUpdate().SetReturnDocument(options.After))
		if result.Err() != nil {
			return &SpaceCrudResponse{
				Error: result.Err().Error(),
			}
		}

		space := Space{}
		result.Decode(&space)

		return &SpaceCrudResponse{
			Space: []Space{space},
		}

	case "DELETE":

		if !req.Space.Id.IsDefined() {
			return &SpaceCrudResponse{
				Error: "id is required for UPDATE operation",
			}
		}

		result := s.spaces.FindOneAndDelete(ctx, req.Space)
		if result.Err() != nil {
			return &SpaceCrudResponse{
				Error: result.Err().Error(),
			}
		}

		space := Space{}
		result.Decode(&space)

		return &SpaceCrudResponse{
			Space: []Space{space},
		}

	default:
		return &SpaceCrudResponse{
			Error: "invalid CRUD operation: " + req.Operation,
		}
	}
}

func (s *SpacesProvider) validateSpaceProviderUnique(ctx context.Context, proto *SpacePrototype) error {
	filter := bson.M{}

	if proto.Id.IsDefined() {
		filter["_id"] = bson.M{"$not": bson.M{"$eq": proto.Id.Get()}}
	}

	if proto.FileProviders.IsDefined() {
		uniq := make(map[string]bool)
		for _, provider := range proto.FileProviders.Get() {
			if uniq[provider.SpaceProviderId] {
				return errors.New("duplicate spaceProviderId: " + provider.SpaceProviderId)
			}
			uniq[provider.SpaceProviderId] = true
			if !strings.HasPrefix(provider.Path, "/") {
				return errors.New("fileProvider " + provider.SpaceProviderId + ": path must start with '/'")
			}
		}

		ids := make([]string, 0)
		for _, provider := range proto.FileProviders.Get() {
			ids = append(ids, provider.SpaceProviderId)
		}
		filter["fileProviders.spaceProviderId"] = bson.M{"$in": ids}
	}

	res, err := s.spaces.Find(ctx, filter)
	if err != nil {
		return fmt.Errorf("error while checking for unique spaceProviderId: %w", err)
	}

	duplicates := make([]Space, 0)
	err = res.All(ctx, &duplicates)
	if err != nil {
		return fmt.Errorf("error while checking for unique spaceProviderId: %w", err)
	}

	if len(duplicates) > 0 {
		return errors.New("the following space already contains a fileProvider with the same spaceProviderId: " + duplicates[0].Id.Hex() + " " + duplicates[0].Title)
	}

	return nil
}
