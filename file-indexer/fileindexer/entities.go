package fileindexer

import (
	"go.mongodb.org/mongo-driver/bson/primitive"
	"umbasa.net/seraph/entities"
)

type FilePrototype struct {
	entities.Prototype

	Id          entities.Definable[primitive.ObjectID] `bson:"_id"`
	ParentDir   entities.Definable[primitive.ObjectID] `bson:"parentDir"`
	ProviderId  entities.Definable[string]             `bson:"providerId"`
	Path        entities.Definable[string]             `bson:"path"`
	SearchWords entities.Definable[string]             `bson:"searchWords"`
	Size        entities.Definable[int64]              `bson:"size"`
	Mode        entities.Definable[int64]              `bson:"mode"`
	ModTime     entities.Definable[int64]              `bson:"modTime"`
	IsDir       entities.Definable[bool]               `bson:"isDir"`
	Mime        entities.Definable[string]             `bson:"mime"`
	ImoHash     entities.Definable[string]             `bson:"imoHash"`
	Pending     entities.Definable[bool]               `bson:"pending"`
}

type File struct {
	Id        primitive.ObjectID `bson:"_id"`
	ParentDir primitive.ObjectID `bson:"parentDir"`
	// Id of the fileprovider that provides the file
	ProviderId string `bson:"providerId"`
	// Path of the file
	Path string `bson:"path"`
	// Path of the file with all non-word characters replaced by space for text indexing purposes
	SearchWords string `bson:"searchWords"`
	// File size in bytes
	Size int64 `bson:"size"`
	// File mode bits
	Mode int64 `bson:"mode"`
	// Unix timestamp of last modification
	ModTime int64 `bson:"modTime"`
	// Whether file is a directory
	IsDir bool `bson:"isDir"`
	// detected mime type of the file
	Mime string `bson:"mime"`
	// imoHash of the file - calculated from 16kb blocks at the beginning, middle and end of file.
	// Can be used to find duplicates.
	ImoHash string `bson:"imoHash"`
	// set to true while calculating and updating file metadata.
	// Used to resume if interrupted during metadata calculation.
	Pending bool `bson:"pending"`
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
