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

package galleryai

import (
	"embed"
	"errors"
	"strings"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/pgx/v5"
	"github.com/golang-migrate/migrate/v4/source/iofs"
)

//go:embed migrations/*.sql
var migrations embed.FS

// ApplyMigrations brings the gallery_ai database schema up to date.
func ApplyMigrations(dbURL string) error {
	d, err := iofs.New(migrations, "migrations")
	if err != nil {
		return err
	}

	// the golang-migrate pgx/v5 driver registers under the pgx5 scheme
	url := strings.Replace(dbURL, "postgres://", "pgx5://", 1)
	url = strings.Replace(url, "postgresql://", "pgx5://", 1)

	mig, err := migrate.NewWithSourceInstance("iofs", d, url)
	if err != nil {
		return err
	}
	defer mig.Close()

	if err := mig.Up(); err != nil && !errors.Is(err, migrate.ErrNoChange) {
		return err
	}
	return nil
}
