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
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/spf13/viper"
	"go.uber.org/fx"
	"umbasa.net/seraph/config"
	"umbasa.net/seraph/gallery-ai/galleryai"
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
			viper.SetDefault("tracing.serviceName", "gallery-ai")
			return viper
		}),
		fx.Provide(
			galleryai.NewConfig,
			galleryai.NewMLClient,
			galleryai.NewThumbnailSource,
			newPool,
			galleryai.New,
		),
		fx.Invoke(func(s *galleryai.Service, lc fx.Lifecycle) {
			lc.Append(fx.StartHook(s.Start))
			lc.Append(fx.StopHook(s.Stop))
		}),
	).Run()
}

func newPool(cfg galleryai.Config, lc fx.Lifecycle) (*pgxpool.Pool, error) {
	if cfg.DBURL == "" {
		return nil, fmt.Errorf("SERAPH_GALLERY_AI_DB_URL is not set")
	}
	if err := galleryai.EnsureDatabase(context.Background(), cfg.DBURL); err != nil {
		return nil, fmt.Errorf("ensure database: %w", err)
	}
	if err := galleryai.ApplyMigrations(cfg.DBURL); err != nil {
		return nil, fmt.Errorf("apply migrations: %w", err)
	}
	pool, err := pgxpool.New(context.Background(), cfg.DBURL)
	if err != nil {
		return nil, fmt.Errorf("connect to database: %w", err)
	}
	lc.Append(fx.StopHook(pool.Close))
	return pool, nil
}
