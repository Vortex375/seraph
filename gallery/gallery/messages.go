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

package gallery

// Operations understood by [GallerySourceFolderCrudRequest].
const (
	GallerySourceFolderOperationList   = "LIST"
	GallerySourceFolderOperationAdd    = "ADD"
	GallerySourceFolderOperationRemove = "REMOVE"
)

// Request to list, add or remove Gallery Source Folders.
//
// UserId is always required and always applied as a filter: the service never
// serves or modifies another user's folders. The gateway takes it from the
// authenticated session and never from the client.
type GallerySourceFolderCrudRequest struct {
	Operation string `bson:"operation" json:"operation"`
	UserId    string `bson:"userId" json:"userId"`

	// Id identifies the folder to remove; used by REMOVE only.
	Id string `bson:"id" json:"id"`

	// SpaceProviderId and Path identify the folder to add; used by ADD only.
	SpaceProviderId string `bson:"spaceProviderId" json:"spaceProviderId"`
	Path            string `bson:"path" json:"path"`
}

// Response carrying the affected Gallery Source Folders.
//
// LIST returns the user's complete set, ADD returns the added (or already
// present) folder and REMOVE returns the removed folder.
type GallerySourceFolderCrudResponse struct {
	Error        string                `bson:"error" json:"error"`
	SourceFolder []GallerySourceFolder `bson:"sourceFolder" json:"sourceFolder"`
}
