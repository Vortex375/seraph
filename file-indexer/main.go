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
		fx.Decorate(func(client *mongo.Client, viper *viper.Viper) *mongo.Client {
			viper.SetDefault("mongo.db", "seraph-files")
			return client
		}),
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
