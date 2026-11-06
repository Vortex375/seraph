// Copyright © 2026 Benjamin Schmitz

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

// Package audiometadata is the audio-metadata service's NATS protocol. It is
// pure Go - the gateway and the thumbnailer import it without TagLib.
package audiometadata

const (
	// TagsRequestTopic answers a TagsRequest with a TagsResponse.
	TagsRequestTopic = "seraph.audio.tags"
	// PictureRequestTopic answers a PictureRequest with one chunk of the
	// file's cover picture in a PictureResponse.
	PictureRequestTopic = "seraph.audio.picture"
)

// MaxPictureChunk is the largest PictureRequest.Length served: well below
// NATS's default 1 MB max payload. Longer requests get a shorter chunk.
const MaxPictureChunk = 512 * 1024

// Error classes in TagsResponse.ErrorClass and PictureResponse.ErrorClass.
const (
	// ErrorClassNotFound: the file does not exist.
	ErrorClassNotFound = "NotFound"
	// ErrorClassUnsupported: not an audio file TagLib can read (or a
	// directory).
	ErrorClassUnsupported = "Unsupported"
	// ErrorClassUnreadable: the file could not be read.
	ErrorClassUnreadable = "Unreadable"
	// ErrorClassNoPicture: an audio file without an embedded picture.
	ErrorClassNoPicture = "NoPicture"
)
