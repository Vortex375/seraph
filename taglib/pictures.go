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

// Picture is one embedded picture of an audio file.
type Picture struct {
	MimeType    string
	Description string
	// PictureType is TagLib's name for the picture's role, e.g. "Front Cover".
	PictureType string
	Data        []byte
}

// Pictures returns the file's embedded pictures, in file order. Every
// intermediate wrapper object is freed here, so the caller only owns ref.
func Pictures(ref FileRef) []Picture {
	n := int(ref.PictureCount())
	pictures := make([]Picture, n)
	for i := range pictures {
		pictures[i] = Picture{
			MimeType:    pictureString(ref, i, "mimeType"),
			Description: pictureString(ref, i, "description"),
			PictureType: pictureString(ref, i, "pictureType"),
			Data:        pictureData(ref, i),
		}
	}
	return pictures
}

func pictureProperty(ref FileRef, index int, key string) Variant {
	k := NewString(key)
	defer DeleteString(k)
	return ref.PictureProperty(uint(index), k)
}

func pictureString(ref FileRef, index int, key string) string {
	v := pictureProperty(ref, index, key)
	defer DeleteVariant(v)
	s := v.ToString()
	defer DeleteString(s)
	return s.ToCString(true)
}

func pictureData(ref FileRef, index int) []byte {
	v := pictureProperty(ref, index, "data")
	defer DeleteVariant(v)
	b := v.ToByteVector()
	defer DeleteByteVector(b)
	return []byte(b.Bytes())
}
