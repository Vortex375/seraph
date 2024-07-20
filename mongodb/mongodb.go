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
