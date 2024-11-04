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

package mongodb

import (
	"context"

	"github.com/spf13/viper"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/bsoncodec"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"go.uber.org/fx"
	"umbasa.net/seraph/entities"
)

var Module = fx.Module("mongodb",
	fx.Provide(
		NewClient,
		NewDb,
	),
)

type ClientParams struct {
	fx.In

	Viper *viper.Viper
	Lc    fx.Lifecycle
}

type ClientResult struct {
	fx.Out

	Client *mongo.Client
}

func getCustomRegistry() *bsoncodec.Registry {
	r := bson.NewRegistry()

	entities.RegisterEncoders(r)

	return r
}

func NewClient(p ClientParams) (ClientResult, error) {
	p.Viper.SetDefault("mongo.url", "mongodb://localhost:27017/")
	uri := p.Viper.GetString("mongo.url")
	client, err := mongo.Connect(context.Background(), options.Client().ApplyURI(uri).SetRegistry(getCustomRegistry()))

	if err != nil {
		return ClientResult{}, err
	}

	p.Lc.Append(fx.StopHook(func(ctx context.Context) error {
		return client.Disconnect(ctx)
	}))

	return ClientResult{
		Client: client,
	}, nil
}

type DbParams struct {
	fx.In

	Viper  *viper.Viper
	Client *mongo.Client
}

type DbResult struct {
	fx.Out

	Db *mongo.Database
}

func NewDb(p DbParams) DbResult {
	dbName := p.Viper.GetString("mongo.db")
	db := p.Client.Database(dbName)

	return DbResult{
		Db: db,
	}
}
