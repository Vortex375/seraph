package fileindexer

import (
	"go.mongodb.org/mongo-driver/bson/primitive"
	"umbasa.net/seraph/entities"
)

type FilePrototype struct {
	entities.Prototype

	Id         entities.Definable[primitive.ObjectID] `bson:"_id"`
	ParentDir  entities.Definable[primitive.ObjectID] `bson:"parentDir"`
	ProviderId entities.Definable[string]             `bson:"providerId"`
	Path       entities.Definable[string]             `bson:"path"`
	Size       entities.Definable[int64]              `bson:"size"`
	Mode       entities.Definable[int64]              `bson:"mode"`
	ModTime    entities.Definable[int64]              `bson:"modTime"`
	IsDir      entities.Definable[bool]               `bson:"isDir"`
	Mime       entities.Definable[string]             `bson:"mime"`
	ImoHash    entities.Definable[string]             `bson:"imoHash"`
	Pending    entities.Definable[bool]               `bson:"pending"`
}

type File struct {
	Id         primitive.ObjectID `bson:"_id"`
	ParentDir  primitive.ObjectID `bson:"parentDir"`
	ProviderId string             `bson:"providerId"`
	Path       string             `bson:"path"`
	Size       int64              `bson:"size"`
	Mode       int64              `bson:"mode"`
	ModTime    int64              `bson:"modTime"`
	IsDir      bool               `bson:"isDir"`
	Mime       string             `bson:"mime"`
	ImoHash    string             `bson:"imoHash"`
	Pending    bool               `bson:"pending"`
}

type ReaddirPrototype struct {
	entities.Prototype

	Readdir   entities.Definable[string]             `bson:"readdir"`
	Index     entities.Definable[int64]              `bson:"index"`
	Total     entities.Definable[int64]              `bson:"total"`
	File      entities.Definable[primitive.ObjectID] `bson:"file"`
	ParentDir entities.Definable[primitive.ObjectID] `bson:"parentDir"`
}

type Readdir struct {
	Id        primitive.ObjectID `bson:"_id"`
	Readdir   string             `bson:"readdir"`
	Index     int64              `bson:"index"`
	Total     int64              `bson:"total"`
	File      primitive.ObjectID `bson:"file"`
	ParentDir primitive.ObjectID `bson:"parentDir"`
}
