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

package taglib

import (
	"strconv"
	"strings"
)

// Tags are an audio file's basic tags and length. Empty strings and zeros
// mean "not set".
type Tags struct {
	Title       string
	Artist      string
	Album       string
	AlbumArtist string
	Genre       string
	Year        int
	TrackNumber int
	DiscNumber  int
	DurationMs  int64
}

// ReadTags reads ref's tags. ref must not be null (see FileRef.IsNull).
// Every by-value wrapper result is freed here, so the caller only owns ref.
func ReadTags(ref FileRef) Tags {
	tag := ref.Tag() // owned by the file
	tags := Tags{
		Title:  utf8(tag.Title()),
		Artist: utf8(tag.Artist()),
		Album:  utf8(tag.Album()),
		Genre:  utf8(tag.Genre()),
		Year:   int(tag.Year()),

		TrackNumber: int(tag.Track()),
	}

	props := ref.Properties()
	defer DeletePropertyMap(props)
	tags.AlbumArtist = property(props, "ALBUMARTIST")
	tags.DiscNumber = leadingNumber(property(props, "DISCNUMBER"))

	// owned by the file; null for a file type without audio properties
	if audio := ref.AudioProperties(); audio.Swigcptr() != 0 {
		tags.DurationMs = int64(audio.LengthInMilliseconds())
	}
	return tags
}

// utf8 converts and frees s.
func utf8(s String) string {
	defer DeleteString(s)
	return s.ToCString(true)
}

// property returns the first value of key, "" when unset.
func property(props PropertyMap, key string) string {
	k := NewString(key)
	defer DeleteString(k)
	values := props.Value(k)
	defer DeleteStringList(values)
	// List<String> is not wrapped; join and take the first value
	sep := NewString("\n")
	defer DeleteString(sep)
	first, _, _ := strings.Cut(utf8(values.ToString(sep)), "\n")
	return first
}

// leadingNumber parses "2" and "2/3" (disc 2 of 3) alike; 0 when not numeric.
func leadingNumber(s string) int {
	n, _ := strconv.Atoi(strings.TrimSpace(strings.SplitN(s, "/", 2)[0]))
	return n
}
