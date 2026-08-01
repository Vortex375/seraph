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

package events

// FileIndexListRequest asks the file index for every entry it knows of
// beneath a given (ProviderId, Path) prefix, one page at a time.
//
// Paging: leave Cursor empty to fetch the first page. To fetch the next
// page, pass back the Cursor value from the previous FileIndexListReply.
type FileIndexListRequest struct {
	RequestId  string `json:"requestId"`
	ProviderId string `json:"providerId"`
	// Path prefix to list beneath. Entries whose path is the prefix itself
	// or a descendant of it (separated by "/") are returned. An empty or
	// unknown prefix yields an empty result rather than an error.
	Path string `json:"path"`
	// Maximum number of entries to return in this page. If <= 0, a
	// server-side default is used.
	PageSize int `json:"pageSize"`
	// Opaque paging cursor obtained from a previous reply's NextCursor.
	// Empty for the first page.
	Cursor string `json:"cursor"`
}

type FileIndexListAck struct {
	RequestId string `json:"requestId"`
	ReplyId   string `json:"replyId"`
	Ack       bool   `json:"ack"`
}

// FileIndexListEntry describes a single file or directory beneath the
// requested prefix.
type FileIndexListEntry struct {
	ProviderId string `json:"providerId"`
	Path       string `json:"path"`
	Size       int64  `json:"size"`
	ModTime    int64  `json:"modTime"`
	IsDir      bool   `json:"isDir"`
	Mime       string `json:"mime"`
}

// FileIndexListReply streams one page of results for a FileIndexListRequest.
// The final message for a request has Last set to true and carries the
// cursor (if any) to continue paging from, in NextCursor.
type FileIndexListReply struct {
	RequestId  string               `json:"requestId"`
	ReplyId    string               `json:"replyId"`
	Entries    []FileIndexListEntry `json:"entries"`
	NextCursor string               `json:"nextCursor"`
	HasMore    bool                 `json:"hasMore"`
	Error      string               `json:"error"`
	Last       bool                 `json:"last"`
}
