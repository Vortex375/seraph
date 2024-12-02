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
	"github.com/spf13/viper"
	"go.mongodb.org/mongo-driver/mongo"
	"go.uber.org/fx"
	"umbasa.net/seraph/config"
	"umbasa.net/seraph/jobs/jobs"
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
			viper.SetDefault("mongo.db", "seraph-jobs")
			return client
		}),
		fx.Provide(jobs.NewMigrations),
		fx.Invoke(func(params jobs.Params, lc fx.Lifecycle) error {
			jobs, err := jobs.NewJobs(params)
			if err != nil {
				return err
			}

			lc.Append(fx.StartHook(func() error {
				return jobs.Start()
			}))

			lc.Append(fx.StopHook(func() {
				jobs.Stop()
			}))

			return nil
		}),
	).Run()
}
