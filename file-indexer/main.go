package main

import (
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/spf13/viper"
	"go.mongodb.org/mongo-driver/mongo"
	"go.uber.org/fx"
	"umbasa.net/seraph/config"
	"umbasa.net/seraph/file-indexer/fileindexer"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/mongodb"
)

func main() {
	fx.New(
		logging.Module,
		config.Module,
		messaging.Module,
		mongodb.Module,
		fx.Invoke(func(nc *nats.Conn, js jetstream.JetStream, db *mongo.Database, log *logging.Logger, viper *viper.Viper, lc fx.Lifecycle) error {

			mig, err := fileindexer.NewMigrations(viper)
			if err != nil {
				return err
			}

			consumer, err := fileindexer.NewConsumer(fileindexer.Params{
				Nc:     nc,
				Js:     js,
				Db:     db,
				Logger: log,
				Mig:    mig,
			})
			if err != nil {
				return err
			}

			lc.Append(fx.StartHook(func() error {
				return consumer.Start()
			}))

			lc.Append(fx.StopHook(func() {
				consumer.Stop()
			}))

			return nil
		}),
	).Run()
}
