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
