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
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/mongodb"
	servicediscovery "umbasa.net/seraph/service-discovery"
	"umbasa.net/seraph/spaces/spaces"
	"umbasa.net/seraph/tracing"
)

func main() {
	fx.New(
		logging.Module,
		messaging.Module,
		config.Module,
		mongodb.Module,
		tracing.Module,
		servicediscovery.Module,
		logging.FxLogger(),
		fx.Provide(spaces.NewMigrations),
		fx.Decorate(func(viper *viper.Viper) *viper.Viper {
			viper.SetDefault("tracing.serviceName", "spaces")
			return viper
		}),
		fx.Decorate(func(client *mongo.Client, viper *viper.Viper) *mongo.Client {
			viper.SetDefault("mongo.db", "seraph-spaces")
			return client
		}),
		fx.Invoke(func(params spaces.Params, discovery servicediscovery.ServiceDiscovery, lc fx.Lifecycle) error {

			result, err := spaces.New(params)

			if err != nil {
				return err
			}

			provider := result.SpacesProvider

			service := discovery.AnnounceService("spaces", map[string]string{})

			lc.Append(fx.StartHook(func() error {
				return provider.Start()
			}))
			lc.Append(fx.StopHook(func() error {
				service.Remove()
				return provider.Stop()
			}))

			return nil
		}),
	).Run()
}
