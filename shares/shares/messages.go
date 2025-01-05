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

type ShareResolveRequest struct {
	ShareId string `bson:"shareId" json:"shareId"`
	Path    string `bson:"path" json:"path"`
}

type ShareResolveResponse struct {
	Error      string `bson:"error" json:"error"`
	ProviderId string `bson:"providerId" json:"providerId"`
	Path       string `bson:"path" json:"path"`
	ReadOnly   bool   `bson:"readOnly" json:"readOnly"`
}

type ShareCrudRequest struct {
	Operation string          `bson:"operation" json:"operation"`
	Share     *SharePrototype `bson:"share" json:"share"`
}

type ShareCrudResponse struct {
	Error string  `bson:"error" json:"error"`
	Share []Share `bson:"share" json:"share"`
}
