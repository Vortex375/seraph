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
	"umbasa.net/seraph/api-gateway/auth"
	"umbasa.net/seraph/api-gateway/gateway"
	"umbasa.net/seraph/api-gateway/jobs"
	"umbasa.net/seraph/api-gateway/preview"
	"umbasa.net/seraph/api-gateway/shares"
	"umbasa.net/seraph/api-gateway/webdav"
	"umbasa.net/seraph/config"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/mongodb"
)

func main() {
	fx.New(
		logging.Module,
		messaging.Module,
		config.Module,
		auth.Module,
		mongodb.Module,
		gateway.Module,
		webdav.Module,
		preview.Module,
		shares.Module,
		jobs.Module,
		logging.FxLogger(),
		fx.Provide(auth.NewMigrations),
		fx.Decorate(func(client *mongo.Client, viper *viper.Viper) *mongo.Client {
			viper.SetDefault("mongo.db", "seraph-auth")
			return client
		}),
		fx.Invoke(func(g gateway.Gateway) {
			// required to bootstrap the Gateway
		}),
	).Run()
}
