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
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/config"
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
			dir := viper.GetString("fileprovider.dir")

			if id == "" {
				return errors.New("missing fileprovider.id argument")
			}

			if dir == "" {
				return errors.New("missing fileprovider.dir argument")
			}

			fs := webdav.Dir(dir)

			lc.Append(fx.StartHook(func() {
				fileprovider.NewFileProviderServer(id, nc, fs, logger)
			}))

			return nil
		}),
	).Run()
}
