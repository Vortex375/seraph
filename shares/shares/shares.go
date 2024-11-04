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
	"errors"
	"fmt"
	"log/slog"
	"path"
	"strings"

	"github.com/nats-io/nats.go"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"go.uber.org/fx"
	"umbasa.net/seraph/logging"
)

const ShareResolveTopic = "seraph.shares.resolve"
const ShareCrudTopic = "seraph.shares.crud"

type Params struct {
	fx.In

	Nc     *nats.Conn
	Db     *mongo.Database
	Logger *logging.Logger
	Mig    Migrations
}

type Result struct {
	fx.Out

	SharesProvider *SharesProvider
}

type SharesProvider struct {
	log        *slog.Logger
	nc         *nats.Conn
	shares     *mongo.Collection
	resolveSub *nats.Subscription
	crudSub    *nats.Subscription
}

func New(p Params) (Result, error) {
	return Result{
		SharesProvider: &SharesProvider{
			log:    p.Logger.GetLogger("shares"),
			nc:     p.Nc,
			shares: p.Db.Collection("shares"),
		},
	}, nil
}

func (s *SharesProvider) Start() error {
	sub, err := s.nc.QueueSubscribe(ShareResolveTopic, ShareResolveTopic, func(msg *nats.Msg) {
		req := ShareResolveRequest{}
		req.Unmarshal(msg.Data)

		resp := s.resolveShare(&req)

		data, _ := resp.Marshal()
		msg.Respond(data)
	})
	if err != nil {
		return fmt.Errorf("While starting SharesProvider: %w", err)
	}
	s.resolveSub = sub
	sub, err = s.nc.QueueSubscribe(ShareCrudTopic, ShareCrudTopic, func(msg *nats.Msg) {
		req := ShareCrudRequest{}
		req.Unmarshal(msg.Data)

		resp := s.handleCrud(&req)

		data, _ := resp.Marshal()
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

func (s *SharesProvider) resolveShare(req *ShareResolveRequest) *ShareResolveResponse {
	filter := SharePrototype{}
	filter.ShareID.Set(req.ShareID)

	result := s.shares.FindOne(context.Background(), filter)
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

func (s *SharesProvider) handleCrud(req *ShareCrudRequest) *ShareCrudResponse {
	switch req.Operation {

	case "READ":
		if req.Share == nil {
			return &ShareCrudResponse{
				Error: "shareID is required for READ operation",
			}
		}

		filter := SharePrototype{}
		filter.ShareID.Set(req.Share.ShareID)
		result := s.shares.FindOne(context.Background(), filter)
		if result.Err() != nil {
			return &ShareCrudResponse{
				Error: result.Err().Error(),
			}
		}

		share := Share{}
		result.Decode(&share)

		return &ShareCrudResponse{
			Share: &share,
		}

	case "CREATE":
		if req.Share == nil {
			return &ShareCrudResponse{
				Error: "share is required for CREATE operation",
			}
		}

		if req.Share.ShareID == "" {
			return &ShareCrudResponse{
				Error: "shareID is required for CREATE operation",
			}
		}

		proto := SharePrototype{}
		req.Share.ToPrototype(&proto)
		_, err := s.shares.InsertOne(context.Background(), proto)

		if err != nil {
			return &ShareCrudResponse{
				Error: err.Error(),
			}
		}

		return &ShareCrudResponse{
			Share: req.Share,
		}

	case "UPDATE":
		if req.Share == nil {
			return &ShareCrudResponse{
				Error: "share is required for UPDATE operation",
			}
		}

		if req.Share.ShareID == "" {
			return &ShareCrudResponse{
				Error: "shareID is required for UPDATE operation",
			}
		}

		filter := SharePrototype{}
		filter.ShareID.Set(req.Share.ShareID)
		proto := SharePrototype{}
		req.Share.ToPrototype(&proto)
		result := s.shares.FindOneAndUpdate(context.Background(), filter, bson.M{"$set": proto},
			options.FindOneAndUpdate().SetReturnDocument(options.After))
		if result.Err() != nil {
			return &ShareCrudResponse{
				Error: result.Err().Error(),
			}
		}

		share := Share{}
		result.Decode(&share)

		return &ShareCrudResponse{
			Share: &share,
		}

	case "DELETE":

		if req.Share == nil {
			return &ShareCrudResponse{
				Error: "share is required for UPDATE operation",
			}
		}

		if req.Share.ShareID == "" {
			return &ShareCrudResponse{
				Error: "shareID is required for UPDATE operation",
			}
		}

		filter := SharePrototype{}
		filter.ShareID.Set(req.Share.ShareID)

		result := s.shares.FindOneAndDelete(context.Background(), filter)
		if result.Err() != nil {
			return &ShareCrudResponse{
				Error: result.Err().Error(),
			}
		}

		share := Share{}
		result.Decode(&share)

		return &ShareCrudResponse{
			Share: &share,
		}

	default:
		return &ShareCrudResponse{
			Error: "invalid CRUD operation: " + req.Operation,
		}
	}
}
