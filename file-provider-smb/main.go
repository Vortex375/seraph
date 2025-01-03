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
	"strings"

	"github.com/spf13/viper"
	"go.uber.org/fx"
	"umbasa.net/seraph/config"
	"umbasa.net/seraph/file-provider-smb/smbprovider"
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
		fx.Invoke(func(params fileprovider.ServerParams, viper *viper.Viper, logger *logging.Logger, lc fx.Lifecycle) error {
			id := viper.GetString("fileprovider.id")
			addr := viper.GetString("fileprovider.addr")
			username := viper.GetString("fileprovider.username")
			password := viper.GetString("fileprovider.password")
			sharename := viper.GetString("fileprovider.sharename")
			pathPrefix := viper.GetString("fileprovider.pathPrefix")
			readOnly := viper.GetBool("fileprovider.readOnly")

			if id == "" {
				return errors.New("missing fileprovider.id argument")
			}
			if addr == "" {
				return errors.New("missing fileprovider.addr argument")
			}
			if sharename == "" {
				return errors.New("missing fileprovider.sharename argument")
			}
			if username == "" {
				username = "guest"
			}

			if !strings.ContainsAny(addr, ":") {
				// addr does not contain port - use default
				addr = addr + ":445"
			}

			fs := smbprovider.NewSmbFileSystem(logger, addr, sharename, username, password, pathPrefix)
			server, err := fileprovider.NewFileProviderServer(params, id, fs, readOnly)
			if err != nil {
				return err
			}

			lc.Append(fx.StartHook(func() {
				server.Start()
			}))

			lc.Append(fx.StopHook(func() {
				server.Stop(false)
				fs.Close()
			}))

			return nil
		}),
	).Run()
}
