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

package jobs

import (
	"embed"

	_ "github.com/golang-migrate/migrate/v4/database/mongodb"
	"github.com/spf13/viper"
	"umbasa.net/seraph/mongodb"
)

//go:embed migrations/*.json
var migrations embed.FS

type Migrations struct{}

func NewMigrations(viper *viper.Viper) (Migrations, error) {
	uri := viper.GetString("mongo.url")
	dbName := viper.GetString("mongo.db")

	err := mongodb.ApplyMigrations(migrations, uri, dbName)

	return Migrations{}, err
}
