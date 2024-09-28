package mongodb

import (
	"embed"
	"errors"

	"github.com/golang-migrate/migrate/v4"
	"github.com/golang-migrate/migrate/v4/source/iofs"
)

func ApplyMigrations(migrations embed.FS, uri string, dbName string) error {
	d, err := iofs.New(migrations, "migrations")
	if err != nil {
		return err
	}

	mig, err := migrate.NewWithSourceInstance("iofs", d, uri+dbName)
	if err != nil {
		return err
	}

	err = mig.Up()
	if err != nil && !errors.Is(err, migrate.ErrNoChange) {
		return err
	}

	return nil
}
