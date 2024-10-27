package main

import (
	"errors"

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

			if providerId == "" {
				return errors.New("misisng 'thumbnailer.providerId' argument: the id of the file provider to use for thumbnail storage")
			}

			params := thumbnailer.Params{
				Nc:     nc,
				Logger: logger,
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
