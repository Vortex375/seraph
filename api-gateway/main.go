package main

import (
	"go.uber.org/fx"
	"umbasa.net/seraph/api-gateway/auth"
	"umbasa.net/seraph/api-gateway/gateway"
	"umbasa.net/seraph/api-gateway/webdav"
	"umbasa.net/seraph/config"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
)

func main() {
	fx.New(
		logging.Module,
		messaging.Module,
		config.Module,
		gateway.Module,
		auth.Module,
		webdav.Module,
		fx.Invoke(func(g gateway.Gateway) {
			// required to bootstrap the Gateway
		}),
	).Run()
}
