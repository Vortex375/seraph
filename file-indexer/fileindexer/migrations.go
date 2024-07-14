package fileindexer

import (
	"embed"
	"errors"

	"github.com/golang-migrate/migrate/v4"
	_ "github.com/golang-migrate/migrate/v4/database/mongodb"
	"github.com/golang-migrate/migrate/v4/source/iofs"
	"github.com/spf13/viper"
)

//go:embed migrations/*.json
var migrations embed.FS

type Migrations struct{}

func NewMigrations(viper *viper.Viper) (Migrations, error) {
	uri := viper.GetString("mongo.url")
	dbName := viper.GetString("mongo.db")

	d, err := iofs.New(migrations, "migrations")
	if err != nil {
		return Migrations{}, err
	}

	mig, err := migrate.NewWithSourceInstance("iofs", d, uri+dbName)
	if err != nil {
		return Migrations{}, err
	}

	err = mig.Up()
	if err != nil && !errors.Is(err, migrate.ErrNoChange) {
		return Migrations{}, err
	}

	return Migrations{}, nil
}
