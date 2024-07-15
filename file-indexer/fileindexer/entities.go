package fileindexer

import "go.mongodb.org/mongo-driver/bson/primitive"

type File struct {
	Id         *primitive.ObjectID `bson:"_id,omitempty"`
	ProviderId string              `bson:"providerId"`
	ParentDir  *primitive.ObjectID `bson:"parentDir"`
	Path       string              `bson:"path"`
	IsDir      bool                `bson:"isDir"`
}
