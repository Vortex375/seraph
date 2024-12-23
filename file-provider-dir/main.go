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
	"errors"

	"github.com/spf13/viper"
	"go.uber.org/fx"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/config"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/tracing"
)

func main() {

	fx.New(
		logging.Module,
		messaging.Module,
		config.Module,
		tracing.Module,
		logging.FxLogger(),
		fx.Decorate(func(viper *viper.Viper) *viper.Viper {
			id := viper.GetString("fileprovider.id")
			viper.SetDefault("tracing.serviceName", "fileprovider."+id)
			return viper
		}),
		fx.Invoke(func(params fileprovider.ServerParams, viper *viper.Viper, lc fx.Lifecycle) error {
			id := viper.GetString("fileprovider.id")
			dir := viper.GetString("fileprovider.dir")
			readOnly := viper.GetBool("fileprovider.readOnly")

			if id == "" {
				return errors.New("missing fileprovider.id argument")
			}

			if dir == "" {
				return errors.New("missing fileprovider.dir argument")
			}

			fs := webdav.Dir(dir)

			lc.Append(fx.StartHook(func() {
				fileprovider.NewFileProviderServer(params, id, fs, readOnly)
			}))

			return nil
		}),
	).Run()
}
