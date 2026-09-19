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

// Rungs of the Capture Date fallback chain, recorded alongside the value so
// the UI can present a fallback differently from a real capture date. Order
// matters: CaptureDateSourceExif is preferred, falling back in the order
// listed.
const (
	// CaptureDateSourceExif means the value came from the photo's own EXIF
	// DateTimeOriginal tag - a real capture date.
	CaptureDateSourceExif = "exif"
	// CaptureDateSourceModTime means EXIF carried no usable date and the
	// value is the file's modification time as reported by the File
	// Provider. This is a weak signal: cloud-side modification time is
	// effectively upload time (see CaptureDateSourceIndexed and the
	// package-level docs), but it is still better than nothing and better
	// than the time the file happened to be processed.
	CaptureDateSourceModTime = "modTime"
	// CaptureDateSourceIndexed means neither EXIF nor a usable modification
	// time was available and the value is the time this item was first
	// captured into the read model.
	CaptureDateSourceIndexed = "indexed"
)

// Reasons a photo could not be decoded, recorded on GalleryPhoto.Unsupported
// rather than omitting the item - backup coverage and display are
// independent questions.
const (
	// UnsupportedReasonFormat means the file is not a decodable image format
	// (e.g. RAW, HEIC) - out of scope for display in this iteration.
	UnsupportedReasonFormat = "format"
	// UnsupportedReasonCorrupt means the file looked like a supported format
	// but could not be decoded - truncated or corrupt data.
	UnsupportedReasonCorrupt = "corrupt"
)

// Prototype object for creating/updating [GalleryPhoto].
type GalleryPhotoPrototype struct {
	entities.Prototype

	Id               entities.Definable[primitive.ObjectID] `bson:"_id"`
	ProviderId       entities.Definable[string]             `bson:"providerId" json:"providerId"`
	Path             entities.Definable[string]             `bson:"path" json:"path"`
	CapturedAt       entities.Definable[int64]              `bson:"capturedAt" json:"capturedAt"`
	CapturedAtSource entities.Definable[string]             `bson:"capturedAtSource" json:"capturedAtSource"`
	Width            entities.Definable[int]                `bson:"width" json:"width"`
	Height           entities.Definable[int]                `bson:"height" json:"height"`
	Orientation      entities.Definable[int]                `bson:"orientation" json:"orientation"`
	Size             entities.Definable[int64]              `bson:"size" json:"size"`
	Mime             entities.Definable[string]             `bson:"mime" json:"mime"`
	Unsupported      entities.Definable[string]             `bson:"unsupported" json:"unsupported"`
	Deleted          entities.Definable[bool]               `bson:"deleted" json:"deleted"`
	IndexedAt        entities.Definable[int64]              `bson:"indexedAt" json:"indexedAt"`
	MetadataPending  entities.Definable[bool]               `bson:"metadataPending" json:"metadataPending"`
	Seq              entities.Definable[int64]              `bson:"seq" json:"seq"`
}

// GalleryPhoto is the gallery read model: one document per physical file
// under a configured Gallery Source Folder, holding everything needed to
// place it in a Capture-Date-ordered listing.
//
// It is keyed PHYSICALLY on (ProviderId, Path) - never on (userId, ...) -
// because that is what FileChangedEvent carries and because the read model
// is deliberately shared across every user who happens to have configured
// the same physical folder: two users including the same family folder cost
// one metadata extraction, not two. Per-user access control is applied at
// query time by resolving each user's Gallery Source Folders, not by
// filtering this collection.
//
// It is upserted on (ProviderId, Path), never inserted, so the same file
// arriving twice - by backfill and a live event, or by two live events -
// produces one document.
type GalleryPhoto struct {
	Id primitive.ObjectID `bson:"_id" json:"id"`

	// physical key: the file provider id and path exactly as carried by
	// FileChangedEvent
	ProviderId string `bson:"providerId" json:"providerId"`
	Path       string `bson:"path" json:"path"`

	// Capture Date: EXIF DateTimeOriginal -> file modification time -> time
	// first indexed. Unix seconds (UTC).
	CapturedAt int64 `bson:"capturedAt" json:"capturedAt"`
	// which rung of the fallback chain produced CapturedAt: one of the
	// CaptureDateSource* constants
	CapturedAtSource string `bson:"capturedAtSource" json:"capturedAtSource"`

	// pixel dimensions as decoded from the file; 0 if not decodable
	Width  int `bson:"width" json:"width"`
	Height int `bson:"height" json:"height"`
	// EXIF orientation (1-8), 0 if unknown/not recorded
	Orientation int `bson:"orientation" json:"orientation"`

	// file size in bytes, as reported by the file-change event
	Size int64 `bson:"size" json:"size"`
	// mime type, as reported by the file-change event
	Mime string `bson:"mime" json:"mime"`

	// set when the file could not be decoded for display; one of the
	// UnsupportedReason* constants. Empty means the file displays normally.
	// An unsupported file is still stored and still appears in the listing -
	// backup coverage and display are independent questions.
	Unsupported string `bson:"unsupported" json:"unsupported"`

	// set by a "deleted" file-change event; a deleted item is excluded from
	// listings rather than physically removed, so a later re-creation at the
	// same path is a normal upsert rather than a resurrection
	Deleted bool `bson:"deleted" json:"deleted"`

	// unix seconds (UTC) this item was first written to the read model; the
	// last rung of the Capture Date fallback chain
	IndexedAt int64 `bson:"indexedAt" json:"indexedAt"`

	// MetadataPending is true when this document was written by backfill
	// (see backfill.go) and has never had byte-level extraction (pixel
	// dimensions, orientation, EXIF Capture Date) run against it, because
	// backfill deliberately reads only the File Index and never opens the
	// file through the File Provider. Such a document is still fully listed
	// (backup coverage and display are independent, exactly like
	// Unsupported) but its CapturedAt is at best rung two of the fallback
	// chain (modification time) and Width/Height/Orientation are zero.
	//
	// A live "created" or "changed" event for the same physical key always
	// runs full extraction and sets this back to false - see upsertPhoto -
	// so a backfilled placeholder self-heals the moment a live event touches
	// it, whether that is the live event that raced the backfill page, or a
	// later edit of the file. Nothing currently re-scans a MetadataPending
	// document on its own; it stays pending until something writes to that
	// path again.
	MetadataPending bool `bson:"metadataPending" json:"metadataPending"`

	// Seq is the delta feed's monotonic sequence number for this document,
	// bumped by GalleryProvider.nextSequence (see sequence.go) on every write
	// that touches it - creation, a live "changed" re-extraction, a backfill
	// upsert, or a "deleted" tombstone. It is never reused, including across
	// a service restart (see nextSequence's docs on how that is guaranteed),
	// and it is what the delta feed (delta.go) pages over: "everything with
	// seq > N" is the entire definition of "changed since N".
	//
	// A document changing twice between two polls still has exactly one Seq
	// value - its latest - because Seq lives ON the document and is
	// overwritten in place, rather than being appended to a separate log of
	// every change. That is deliberate: it lets a client that missed several
	// intermediate polls catch up with one read of current state per changed
	// item, instead of replaying every intermediate write.
	Seq int64 `bson:"seq" json:"seq"`
}
