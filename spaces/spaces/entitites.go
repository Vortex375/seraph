package spaces

import (
	"go.mongodb.org/mongo-driver/bson/primitive"
	"umbasa.net/seraph/entities"
)

type SpacePrototype struct {
	entities.Prototype

	Id            entities.Definable[primitive.ObjectID]  `bson:"_id"`
	Title         entities.Definable[string]              `bson:"title" json:"title"`
	Description   entities.Definable[string]              `bson:"description" json:"description"`
	Users         entities.Definable[[]string]            `bson:"users" json:"users"`
	FileProviders entities.Definable[[]SpaceFileProvider] `bson:"fileProviders" json:"fileProviders"`
}

type Space struct {
	Id            primitive.ObjectID  `bson:"_id"`
	Title         string              `bson:"title" json:"title"`
	Description   string              `bson:"description" json:"description"`
	Users         []string            `bson:"users" json:"users"`
	FileProviders []SpaceFileProvider `bson:"fileProviders" json:"fileProviders"`
}

type SpaceFileProvider struct {
	SpaceProviderId string `bson:"spaceProviderId" json:"spaceProviderId"`
	ProviderId      string `bson:"providerId" json:"providerId"`
	Path            string `bson:"path" json:"path"`
	ReadOnly        bool   `bson:"readOnly" json:"readOnly"`
}
