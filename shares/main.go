package main

import (
	"go.uber.org/fx"
	"umbasa.net/seraph/config"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/mongodb"
	"umbasa.net/seraph/shares/shares"
)

func main() {
	fx.New(
		logging.Module,
		messaging.Module,
		config.Module,
		mongodb.Module,
		fx.Provide(shares.NewMigrations),
		fx.Invoke(func(params shares.Params, lc fx.Lifecycle) error {

			result, err := shares.New(params)

			if err != nil {
				return err
			}

			provider := result.SharesProvider
			lc.Append(fx.StartHook(func() error {
				return provider.Start()
			}))
			lc.Append(fx.StopHook(func() error {
				return provider.Stop()
			}))

			return nil
		}),
	).Run()
}
