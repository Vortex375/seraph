// Copyright © 2026 Benjamin Schmitz

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
	"github.com/spf13/viper"
	"go.uber.org/fx"
	"umbasa.net/seraph/audio-metadata/tagreader"
	"umbasa.net/seraph/config"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	servicediscovery "umbasa.net/seraph/service-discovery"
	"umbasa.net/seraph/tracing"
)

func main() {
	fx.New(
		logging.Module,
		messaging.Module,
		config.Module,
		tracing.Module,
		servicediscovery.Module,
		logging.FxLogger(),
		fx.Decorate(func(viper *viper.Viper) *viper.Viper {
			viper.SetDefault("tracing.serviceName", "audio-metadata")
			return viper
		}),
		fx.Invoke(func(nc *nats.Conn, logger *logging.Logger, discovery servicediscovery.ServiceDiscovery, lc fx.Lifecycle) {
			responder := tagreader.NewResponder(nc, logger, tagreader.NewReader(tagreader.ProviderOpener(nc, logger)))
			service := discovery.AnnounceService("audio-metadata", map[string]string{})

			lc.Append(fx.StartHook(responder.Start))
			lc.Append(fx.StopHook(func() error {
				service.Remove()
				return responder.Stop()
			}))
		}),
	).Run()
}
