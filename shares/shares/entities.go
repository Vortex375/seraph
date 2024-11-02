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

func (s *Share) ToPrototype(proto *SharePrototype) {
	proto.ShareID.Set(s.ShareID)
	proto.Owner.Set(s.Owner)
	proto.Title.Set(s.Title)
	proto.Description.Set(s.Description)
	proto.ProviderID.Set(s.ProviderID)
	proto.Path.Set(s.Path)
	proto.Recursive.Set(s.Recursive)
	proto.IsDir.Set(s.IsDir)
}
