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

// GalleryDeltaTopic is the NATS request/reply subject for
// [GalleryDeltaRequest], following the same plain request/reply shape as
// [GalleryListTopic].
const GalleryDeltaTopic = "seraph.gallery.delta"

// DefaultDeltaPageSize/MaxDeltaPageSize mirror DefaultListPageSize/
// MaxListPageSize: a page bound the request can lower but never raise past
// the max, so a single poll can never force the service to walk or return an
// unbounded number of changes.
const DefaultDeltaPageSize = 500
const MaxDeltaPageSize = 2000

// GalleryDeltaRequest asks for one page of everything that has changed in
// the requesting user's gallery since Since.
//
// UserId is the sole access-control input, exactly like GalleryListRequest:
// the feed is scoped to this user's own Gallery Source Folders, resolved for
// this user at request time, so it inherits the listing's access control
// rather than implementing a second one - a folder whose access was revoked
// simply stops resolving and its photos stop being reachable by the feed,
// the same way they stop appearing in the listing.
type GalleryDeltaRequest struct {
	UserId string `json:"userId"`

	// Since is the last sequence value the client has already seen (see
	// GalleryDeltaItem.Seq / GalleryDeltaResponse.NextSince). Zero means "the
	// beginning" - the client has seen nothing yet, so the response starts
	// cold-syncing the user's entire current gallery from the delta feed
	// alone, tombstones included (there are none yet for a client that has
	// seen nothing).
	Since int64 `json:"since"`

	// PageSize is the maximum number of items to return. If <= 0,
	// DefaultDeltaPageSize is used; values above MaxDeltaPageSize are capped.
	PageSize int `json:"pageSize"`

	// Cursor continues a page in progress. Empty for the first request at a
	// given Since. See GalleryDeltaResponse.NextCursor for what it encodes
	// and why it is safe across an app restart.
	Cursor string `json:"cursor"`
}

// GalleryDeltaItem is one changed row in the delta feed: either the current
// state of a photo (Tombstone false) or notice that it has been removed
// (Tombstone true). A mirror applies a non-tombstone item as an upsert and a
// tombstone as a delete, keyed on (ProviderId, Path) - the same SPACE
// coordinates the listing API returns, so a mirror keyed off listing results
// and a mirror keyed off delta results agree on identity.
type GalleryDeltaItem struct {
	// ProviderId is the SPACE provider id, exactly like GalleryListItem.
	ProviderId string `json:"providerId"`
	// Path is the SPACE path, exactly like GalleryListItem.
	Path string `json:"path"`

	// Seq is this item's current delta sequence: the value the client has
	// "seen" this item up to once it has processed this row. It is safe (and
	// expected) for a client to persist the maximum Seq it has seen across
	// every item in every page and pass it back as the next request's Since.
	Seq int64 `json:"seq"`

	// Tombstone is true when this row represents a removal: the photo was
	// deleted (or its physical key otherwise stopped being visible) and a
	// mirror holding it locally should remove it. Every other field below is
	// zero-valued on a tombstone row - there is no "current state" for a
	// removed item beyond its identity and its Seq.
	Tombstone bool `json:"tombstone"`

	CapturedAt       int64  `json:"capturedAt"`
	CapturedAtSource string `json:"capturedAtSource"`

	Width       int `json:"width"`
	Height      int `json:"height"`
	Orientation int `json:"orientation"`

	Size int64  `json:"size"`
	Mime string `json:"mime"`

	Unsupported     string `json:"unsupported"`
	MetadataPending bool   `json:"metadataPending"`
}

// GalleryDeltaResponse carries one page of delta feed results.
type GalleryDeltaResponse struct {
	Error string `json:"error"`

	Items []GalleryDeltaItem `json:"items"`

	// NextCursor continues the CURRENT page scan when HasMore is true - pass
	// it back as GalleryDeltaRequest.Cursor together with the SAME Since used
	// to obtain it. It encodes a position in the (seq) keyset, not an offset,
	// so it is safe to persist to disk and resume from after an app restart:
	// resuming from a stored cursor can neither skip a changed item nor
	// re-deliver one already applied, independent of how long the gap until
	// resumption is or what changed on the server in the meantime.
	NextCursor string `json:"nextCursor"`
	HasMore    bool   `json:"hasMore"`

	// NextSince is the sequence value to pass as the NEXT poll's Since once
	// this page (and every prior page of the same poll, if any) has been
	// applied - i.e. once HasMore is false. It is the maximum Seq observed
	// across every item examined during this poll (including rows skipped
	// because they fell outside the user's resolved folders - see delta.go),
	// so resuming from it is guaranteed not to miss a change that arrived
	// after this poll started scanning but was assigned a Seq at or below it.
	NextSince int64 `json:"nextSince"`
}
