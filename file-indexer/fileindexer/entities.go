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
	Size       entities.Definable[int64]              `avro:"size"`
	Mode       entities.Definable[int64]              `avro:"mode"`
	ModTime    entities.Definable[int64]              `avro:"modTime"`
	IsDir      entities.Definable[bool]               `bson:"isDir"`
	Readdir    entities.Definable[string]             `avro:"readdir"`
}

type File struct {
	Id         primitive.ObjectID `bson:"_id"`
	ParentDir  primitive.ObjectID `bson:"parentDir"`
	ProviderId string             `bson:"providerId"`
	Path       string             `bson:"path"`
	Size       int64              `avro:"size"`
	Mode       int64              `avro:"mode"`
	ModTime    int64              `avro:"modTime"`
	IsDir      bool               `bson:"isDir"`
	Readdir    string             `avro:"readdir"`
}
