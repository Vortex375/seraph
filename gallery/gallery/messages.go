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

// GalleryListTopic is the NATS request/reply subject for
// [GalleryListRequest], following the same plain request/reply shape as
// [GallerySourceFolderCrudTopic] rather than the ack-then-stream shape some
// other services use for paged queries - the gallery service does not use
// that pattern anywhere else, so there is nothing to stay consistent with by
// adopting it here.
const GalleryListTopic = "seraph.gallery.list"

// DefaultListPageSize is used when a request does not specify a positive
// PageSize.
const DefaultListPageSize = 200

// MaxListPageSize caps the number of entries returned in a single page,
// regardless of what the request asks for.
const MaxListPageSize = 1000

// GalleryListRequest asks for a page of the requesting user's gallery
// listing, Capture-Date ordered, newest first.
//
// UserId is always required and is the sole access-control input: the
// listing is scoped to exactly this user's own Gallery Source Folders,
// each resolved for this user at query time (see [GalleryProvider]'s query
// implementation). The gateway takes it from the authenticated session and
// never from the client, exactly like [GallerySourceFolderCrudRequest].
type GalleryListRequest struct {
	UserId string `json:"userId"`

	// PageSize is the maximum number of items to return. If <= 0,
	// DefaultListPageSize is used; values above MaxListPageSize are capped.
	PageSize int `json:"pageSize"`

	// Cursor is an opaque paging token obtained from a previous
	// GalleryListResponse.NextCursor. Empty for the first page. It encodes a
	// position in the (capturedAt desc, _id) keyset - not a page number or
	// an offset - so paging remains stable (no skips, no duplicates) even as
	// items are inserted or removed between page fetches.
	Cursor string `json:"cursor"`
}

// GalleryListItem is one photo in a listing response. Path is a SPACE path -
// translated from the read model's physical (providerId, path) key at query
// time using the Gallery Source Folder it was resolved through - so the app
// can feed ProviderId+Path straight into the existing preview/download
// endpoints (their "p" query parameter is "<spaceProviderId><path>") with no
// new plumbing.
type GalleryListItem struct {
	// ProviderId is the SPACE provider id (SpaceProviderId of the Gallery
	// Source Folder this item was reached through), not the physical file
	// provider id.
	ProviderId string `json:"providerId"`
	// Path is the SPACE path, not the physical path.
	Path string `json:"path"`

	CapturedAt       int64  `json:"capturedAt"`
	CapturedAtSource string `json:"capturedAtSource"`

	Width       int `json:"width"`
	Height      int `json:"height"`
	Orientation int `json:"orientation"`

	Size int64  `json:"size"`
	Mime string `json:"mime"`

	// Unsupported is set (to one of the UnsupportedReason* constants) when
	// this file could not be decoded for display. It still appears in the
	// listing - backup coverage and display are independent questions - so
	// the app can show a placeholder rather than the item silently missing.
	Unsupported string `json:"unsupported"`

	// MetadataPending is true when this item was populated by backfill and
	// has not yet had byte-level extraction (Capture Date from EXIF, pixel
	// dimensions, orientation) run against it - see
	// [gallery.GalleryPhoto.MetadataPending]. CapturedAt is still populated
	// (from the File Index's modification time, or "first indexed" as a last
	// resort) so the item sorts sensibly, but the app should treat it as
	// provisional: a real EXIF Capture Date and dimensions will appear later
	// without any action needed, the moment a live file-change event touches
	// this path.
	MetadataPending bool `json:"metadataPending"`
}

// GalleryListResponse carries one page of a gallery listing.
type GalleryListResponse struct {
	Error string `json:"error"`

	Items []GalleryListItem `json:"items"`

	// NextCursor continues paging when HasMore is true; pass it back as
	// GalleryListRequest.Cursor. Empty when HasMore is false.
	NextCursor string `json:"nextCursor"`
	HasMore    bool   `json:"hasMore"`
}
