package auth

import (
	"embed"

	"github.com/spf13/viper"
	"umbasa.net/seraph/mongodb"

	_ "github.com/golang-migrate/migrate/v4/database/mongodb"
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
