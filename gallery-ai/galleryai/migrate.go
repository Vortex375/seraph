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
	"context"
	"embed"
	"errors"
	"fmt"
	"strings"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/pgx/v5"
	"github.com/golang-migrate/migrate/v4/source/iofs"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

//go:embed migrations/*.sql
var migrations embed.FS

// EnsureDatabase creates the database named in dbURL if it does not exist yet,
// connecting to the server's "postgres" database. An "already exists" error
// (a concurrent creator won the race) counts as success.
func EnsureDatabase(ctx context.Context, dbURL string) error {
	cfg, err := pgx.ParseConfig(dbURL)
	if err != nil {
		return fmt.Errorf("parse database url: %w", err)
	}
	name := cfg.Database
	cfg.Database = "postgres"
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return fmt.Errorf("connect to postgres: %w", err)
	}
	defer conn.Close(ctx)

	var exists bool
	if err := conn.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)`, name).Scan(&exists); err != nil {
		return fmt.Errorf("check database: %w", err)
	}
	if exists {
		return nil
	}
	_, err = conn.Exec(ctx, `CREATE DATABASE `+pgx.Identifier{name}.Sanitize())
	var pgErr *pgconn.PgError
	if err != nil && !(errors.As(err, &pgErr) && pgErr.Code == "42P04") {
		return fmt.Errorf("create database %s: %w", name, err)
	}
	return nil
}

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
