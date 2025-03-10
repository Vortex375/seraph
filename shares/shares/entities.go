// Copyright © 2024 Benjamin Schmitz

// This file is part of Seraph <https://github.com/Vortex375/seraph>.

// Seraph is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License
// as published by the Free Software Foundation,
// either version 3 of the License, or (at your option)
// any later version.

// Seraph is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.

// You should have received a copy of the GNU Affero General Public License
// along with Seraph.  If not, see <http://www.gnu.org/licenses/>.

package shares

import (
	"go.mongodb.org/mongo-driver/bson/primitive"
	"umbasa.net/seraph/entities"
)

type SharePrototype struct {
	entities.Prototype

	ShareId     entities.Definable[string] `bson:"shareId"`
	Owner       entities.Definable[string] `bson:"owner"`
	Title       entities.Definable[string] `bson:"title"`
	Description entities.Definable[string] `bson:"description"`
	ProviderId  entities.Definable[string] `bson:"providerId"`
	Path        entities.Definable[string] `bson:"path"`
	Recursive   entities.Definable[bool]   `bson:"recursive"`
	ReadOnly    entities.Definable[bool]   `bson:"readOnly"`
	IsDir       entities.Definable[bool]   `bson:"isDir"`
}

type Share struct {
	Id          primitive.ObjectID `bson:"_id"`
	ShareId     string             `bson:"shareId" json:"shareId"`
	Owner       string             `bson:"owner" json:"owner"`
	Title       string             `bson:"title" json:"title"`
	Description string             `bson:"description" json:"description"`
	ProviderId  string             `bson:"providerId" json:"providerId"`
	Path        string             `bson:"path" json:"path"`
	Recursive   bool               `bson:"recursive" json:"recursive"`
	ReadOnly    bool               `bson:"readOnly"`
	IsDir       bool               `bson:"isDir" json:"isDir"`
}
