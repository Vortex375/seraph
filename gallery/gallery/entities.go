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

import (
	"go.mongodb.org/mongo-driver/bson/primitive"
	"umbasa.net/seraph/entities"
)

// Prototype object for creating [GallerySourceFolder]
type GallerySourceFolderPrototype struct {
	entities.Prototype

	Id              entities.Definable[primitive.ObjectID] `bson:"_id"`
	UserId          entities.Definable[string]             `bson:"userId" json:"userId"`
	SpaceProviderId entities.Definable[string]             `bson:"spaceProviderId" json:"spaceProviderId"`
	Path            entities.Definable[string]             `bson:"path" json:"path"`
	BackfillDone    entities.Definable[bool]               `bson:"backfillDone"`
	BackfillCursor  entities.Definable[string]             `bson:"backfillCursor"`
}

// Entity representing a Gallery Source Folder: a folder in Seraph whose photos
// appear in Gallery Mode.
//
// Gallery Source Folders are stored in Space terms - (SpaceProviderId, Path) -
// exactly as the user picked them in the folder picker. Storing them physically
// would force the app to translate before saving and would silently invalidate
// the configuration whenever an administrator re-mounted a Space.
//
// They belong to a user, not to a device: one user's folders are never visible
// to another.
type GallerySourceFolder struct {
	// internal Id of the GallerySourceFolder entity
	Id primitive.ObjectID `bson:"_id" json:"id"`

	// user id of the owner of this Gallery Source Folder
	UserId string `bson:"userId" json:"userId"`

	// the space provider id, as picked by the user
	SpaceProviderId string `bson:"spaceProviderId" json:"spaceProviderId"`

	// the path within the space, as picked by the user
	Path string `bson:"path" json:"path"`

	// BackfillDone is true once the paged File Index prefix query for this
	// folder's resolved physical prefix has run to completion - i.e. every
	// page up to HasMore=false has been fed through the read-model upsert
	// path. See backfill.go.
	BackfillDone bool `bson:"backfillDone" json:"-"`

	// BackfillCursor is the last FileIndexListReply.NextCursor consumed so
	// far, so that a backfill interrupted by a restart (before BackfillDone
	// is set) resumes from roughly where it left off rather than rescanning
	// the whole prefix from the beginning. This is a resume-efficiency
	// optimization only, never a correctness requirement: every page,
	// resumed or not, is fed through the same upsert-on-(providerId, path)
	// path live events use, so even a full restart-from-scratch (empty
	// cursor) can never produce a duplicate gallery item - see
	// TestBackfillRestartDoesNotDuplicate.
	BackfillCursor string `bson:"backfillCursor" json:"-"`
}
