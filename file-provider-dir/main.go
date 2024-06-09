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
		fx.Invoke(func(nc *nats.Conn, viper *viper.Viper, logger *logging.Logger) error {
			id := viper.GetString("fileprovider.id")
			dir := viper.GetString("fileprovider.dir")

			if id == "" {
				return errors.New("missing fileprovider.id argument")
			}

			if dir == "" {
				return errors.New("missing fileprovider.dir argument")
			}

			fs := webdav.Dir(dir)
			fileprovider.NewFileProviderServer(id, nc, fs, logger)

			return nil
		}),
	).Run()
}
