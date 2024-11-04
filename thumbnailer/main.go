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
	"image/jpeg"

	"github.com/nats-io/nats.go"
	"github.com/spf13/viper"
	"go.uber.org/fx"
	"umbasa.net/seraph/config"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/thumbnailer/thumbnailer"
)

func main() {
	fx.New(
		logging.Module,
		messaging.Module,
		config.Module,
		fx.Invoke(func(nc *nats.Conn, viper *viper.Viper, logger *logging.Logger, lc fx.Lifecycle) error {
			providerId := viper.GetString("thumbnailer.providerId")
			path := viper.GetString("thumbnailer.path")
			viper.SetDefault("thumbnailer.jpegQuality", jpeg.DefaultQuality)
			jpegQuality := viper.GetInt("thumbnailer.jpegQuality")

			if providerId == "" {
				return errors.New("misisng 'thumbnailer.providerId' argument: the id of the file provider to use for thumbnail storage")
			}

			params := thumbnailer.Params{
				Nc:     nc,
				Logger: logger,
				Options: &thumbnailer.Options{
					JpegQuality: jpegQuality,
				},
			}
			client := fileprovider.NewFileProviderClient(providerId, nc, logger)

			result, err := thumbnailer.NewThumbnailer(params, providerId, path, client)
			if err != nil {
				return err
			}

			thumb := result.Thumbnailer
			lc.Append(fx.StartHook(func() error {
				return thumb.Start()
			}))
			lc.Append(fx.StopHook(func() error {
				return thumb.Stop()
			}))

			return nil
		}),
	).Run()
}
