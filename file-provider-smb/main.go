// Copyright © 2024 Benjamin Schmitz

// This file is part of Seraph.

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

	"github.com/nats-io/nats.go"
	"github.com/spf13/viper"
	"go.uber.org/fx"
	"umbasa.net/seraph/config"
	"umbasa.net/seraph/file-provider-smb/smbprovider"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
)

func main() {

	fx.New(
		logging.Module,
		messaging.Module,
		config.Module,
		fx.Invoke(func(nc *nats.Conn, viper *viper.Viper, logger *logging.Logger, lc fx.Lifecycle) error {
			id := viper.GetString("fileprovider.id")
			addr := viper.GetString("fileprovider.addr")
			username := viper.GetString("fileprovider.username")
			password := viper.GetString("fileprovider.password")
			sharename := viper.GetString("fileprovider.sharename")

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

			fs := smbprovider.NewSmbFileSystem(logger, addr, sharename, username, password)
			fileprovider.NewFileProviderServer(id, nc, fs, logger)

			lc.Append(fx.StopHook(func() {
				fs.Close()
			}))

			return nil
		}),
	).Run()
}
