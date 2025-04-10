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
	"runtime"

	"github.com/spf13/viper"
	"go.uber.org/fx"
	"umbasa.net/seraph/config"
	"umbasa.net/seraph/file-indexer/fileindexer"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/mongodb"
	servicediscovery "umbasa.net/seraph/service-discovery"
	"umbasa.net/seraph/tracing"
)

func main() {
	fx.New(
		logging.Module,
		config.Module,
		messaging.Module,
		mongodb.Module,
		tracing.Module,
		servicediscovery.Module,
		logging.FxLogger(),
		fx.Decorate(func(viper *viper.Viper) *viper.Viper {
			viper.SetDefault("tracing.serviceName", "fileindexer")
			viper.SetDefault("fileindexer.parallel", runtime.NumCPU())
			viper.SetDefault("mongo.db", "seraph-files")
			return viper
		}),
		fx.Provide(fileindexer.NewMigrations),
		fx.Provide(fileindexer.NewConsumer),
		fx.Invoke(func(consumer fileindexer.Consumer, discovery servicediscovery.ServiceDiscovery, lc fx.Lifecycle) {

			service := discovery.AnnounceService("file-indexer", map[string]string{})

			lc.Append(fx.StartHook(func() error {
				return consumer.Start()
			}))

			lc.Append(fx.StopHook(func() {
				service.Remove()
				consumer.Stop()
			}))

		}),
	).Run()
}
