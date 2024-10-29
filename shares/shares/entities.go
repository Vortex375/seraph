package shares

import (
	"go.mongodb.org/mongo-driver/bson/primitive"
	"umbasa.net/seraph/entities"
)

type SharePrototype struct {
	entities.Prototype

	ShareID     entities.Definable[string] `bson:"shareId"`
	Owner       entities.Definable[string] `bson:"owner"`
	Title       entities.Definable[string] `bson:"title"`
	Description entities.Definable[string] `bson:"description"`
	ProviderID  entities.Definable[string] `bson:"providerId"`
	Path        entities.Definable[string] `bson:"path"`
	Recursive   entities.Definable[bool]   `bson:"recursive"`
	IsDir       entities.Definable[bool]   `bson:"isDir"`
}

type ShareEntity struct {
	Share

	Id primitive.ObjectID `bson:"_id"`
}
