package config

import (
	"strings"

	"github.com/spf13/viper"
	"go.uber.org/fx"
	"umbasa.net/seraph/logging"
)

var Module = fx.Module("config",
	fx.Provide(
		New,
	),
)

type Params struct {
	fx.In

	Logger *logging.Logger
}

type Result struct {
	fx.Out

	Viper *viper.Viper
}

func New(p Params) (Result, error) {
	log := p.Logger.GetLogger("config")
	v := viper.New()

	v.SetEnvPrefix("seraph")
	v.AutomaticEnv()
	v.SetEnvKeyReplacer(strings.NewReplacer(".", "_"))

	v.SetConfigName("config")
	v.SetConfigType("yaml")
	v.AddConfigPath(".")
	if err := v.ReadInConfig(); err != nil {
		if _, ok := err.(viper.ConfigFileNotFoundError); ok {
			log.Info("no configuration file found")
		} else {
			log.Error("error reading config file", "error", err)
			return Result{}, err
		}
	} else {
		log.Info("loaded configuration file", "file", v.ConfigFileUsed())
	}

	return Result{
		Viper: v,
	}, nil
}
