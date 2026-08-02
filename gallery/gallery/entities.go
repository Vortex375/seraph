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

	Id                 entities.Definable[primitive.ObjectID] `bson:"_id"`
	UserId             entities.Definable[string]             `bson:"userId" json:"userId"`
	SpaceProviderId    entities.Definable[string]             `bson:"spaceProviderId" json:"spaceProviderId"`
	Path               entities.Definable[string]             `bson:"path" json:"path"`
	BackfillDone       entities.Definable[bool]               `bson:"backfillDone"`
	BackfillCursor     entities.Definable[string]             `bson:"backfillCursor"`
	PhysicalProviderId entities.Definable[string]             `bson:"physicalProviderId"`
	PhysicalPath       entities.Definable[string]             `bson:"physicalPath"`
	RescanRunning      entities.Definable[bool]               `bson:"rescanRunning"`
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

	// PhysicalProviderId/PhysicalPath hold this folder's currently resolved
	// physical prefix - the (providerId, path) resolveSpace returns for it -
	// kept in step by refreshPrefixCache (ingest.go), which is the seam every
	// resolution trigger shares: startup, ADD, and a relevant spaces.changed
	// event. An administrator re-pointing a Space at a different File
	// Provider therefore updates this alongside the in-memory ingestion
	// prefix cache, rather than leaving it pinned to where the folder used to
	// live.
	//
	// It is never used for access control - that is always a fresh
	// resolveSpace call (resolveFoldersForUser, refreshPrefixCache) and stays
	// that way. Its one purpose is letting REMOVE scope its delta-feed
	// tombstone sweep (recordRemovalTombstones in delta.go, called from
	// removeSourceFolder) over the photos this folder made visible, WITHOUT
	// resolving the Space again: REMOVE's tested contract is that it contacts
	// no other service (see TestRemoveTouchesNoFileProvider), so the
	// persisted prefix is the only physical location available to it at all.
	//
	// The one case where it can lag reality is a folder that stopped
	// resolving entirely (access revoked, Space deleted): refreshPrefixCache
	// deliberately leaves the last known value in place rather than clearing
	// it, since a stale-but-real prefix still sweeps the right documents far
	// more often than an empty one, which would sweep none at all.
	PhysicalProviderId string `bson:"physicalProviderId" json:"-"`
	PhysicalPath       string `bson:"physicalPath" json:"-"`

	// RescanRunning is true while a genuine File Provider re-scan triggered
	// by RESCAN (see rescan.go) is walking this folder's physical tree. It is
	// the ONLY state a RESCAN request needs to check to refuse starting a
	// second concurrent scan over the same folder (see startRescan), and it
	// is what the app polls (via LIST) to show "rescan running" / "rescan
	// finished" feedback - there is no separate job/progress channel.
	//
	// Persisted rather than held only in memory so that a service restart
	// mid-scan does not leave the flag stuck true forever with nothing to
	// ever clear it: resumeIncompleteRescans (rescan.go) clears or resumes
	// exactly like resumeIncompleteBackfills does for BackfillDone.
	RescanRunning bool `bson:"rescanRunning" json:"rescanRunning"`
}
