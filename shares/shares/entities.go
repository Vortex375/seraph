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

// Prototype object for creating or updating [Share]
type SharePrototype struct {
	entities.Prototype

	ShareId     entities.Definable[string] `bson:"shareId" json:"shareId"`
	Owner       entities.Definable[string] `bson:"owner" json:"owner"`
	Title       entities.Definable[string] `bson:"title" json:"title"`
	Description entities.Definable[string] `bson:"description" json:"description"`
	ProviderId  entities.Definable[string] `bson:"providerId" json:"providerId"`
	Path        entities.Definable[string] `bson:"path" json:"path"`
	Recursive   entities.Definable[bool]   `bson:"recursive" json:"recursive"`
	ReadOnly    entities.Definable[bool]   `bson:"readOnly" json:"readOnly"`
	IsDir       entities.Definable[bool]   `bson:"isDir" json:"isDir"`
}

// Entity representing a "share", i.e. information that makes
// a file or folder publicly available by sharing a link containig the shareId.
type Share struct {
	// internal Id of the Share entity
	Id primitive.ObjectID `bson:"_id" json:"id"`

	// the ShareId is publicly visible (e.g. in share links) and must be unique
	ShareId string `bson:"shareId" json:"shareId"`

	// user id of the Owner of the Share. The owner must have access to the shared files
	// or else the share will not work
	Owner string `bson:"owner" json:"owner"`

	// an optional Title that can be shown when opening the share
	Title string `bson:"title" json:"title"`

	// an optional Description text that can be shown when opening the share
	Description string `bson:"description" json:"description"`

	// the ProviderId of the file provider that hosts the shared file or folder
	ProviderId string `bson:"providerId" json:"providerId"`

	// the Path to the shared file or folder (respective to the provider)
	Path string `bson:"path" json:"path"`

	// when sharing a folder, determines whether sub-folders are shared as well
	Recursive bool `bson:"recursive" json:"recursive"`

	// determines whether users can modify files using the share
	// TODO: support multiple modes, e.g. "upload only"
	ReadOnly bool `bson:"readOnly" json:"readOnly"`

	// whether a file or folder is shared
	IsDir bool `bson:"isDir" json:"isDir"`
}
