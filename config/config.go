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
