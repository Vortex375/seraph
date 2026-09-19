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
	"bufio"
	"bytes"
	"errors"
	"image"
	"io"
	"strings"
	"time"

	"github.com/rwcarlsen/goexif/exif"

	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
)

// photoMetadata is what metadata extraction produces for one file. It is
// deliberately decoupled from GalleryPhoto so extraction can be tested and
// reasoned about without a database.
type photoMetadata struct {
	// CapturedAt / CapturedAtSource are only set by the caller (extractMetadata
	// does not know the file-change event's ModTime or the "first indexed"
	// time - see resolveCaptureDate), but Width/Height/Orientation/Unsupported
	// come straight from decoding the file.
	Width       int
	Height      int
	Orientation int
	// Unsupported is set (to one of the UnsupportedReason* constants) when the
	// file could not be decoded. The other fields are then zero. This is not
	// an error return: a file that cannot be decoded is still a valid,
	// storable result - "backup coverage and display are independent
	// questions".
	Unsupported string
}

// extractMetadata decodes pixel dimensions and EXIF orientation from image
// bytes. A file that is not a recognized image format, or that is truncated
// or otherwise corrupt, is reported via Unsupported rather than as a Go
// error: callers must still store the item.
//
// r must support Seek back to the start; extractMetadata reads it twice
// (once via image.DecodeConfig, once for EXIF).
func extractMetadata(r io.ReadSeeker) photoMetadata {
	width, height, unsupported := decodeDimensions(r)
	if unsupported != "" {
		return photoMetadata{Unsupported: unsupported}
	}

	orientation := 0
	if _, err := r.Seek(0, io.SeekStart); err == nil {
		orientation = decodeOrientation(r)
	}

	return photoMetadata{
		Width:       width,
		Height:      height,
		Orientation: orientation,
	}
}

// decodeDimensions reports the pixel dimensions of the image in r, and an
// UnsupportedReason if it cannot be decoded at all.
func decodeDimensions(r io.ReadSeeker) (width int, height int, unsupported string) {
	cfg, _, err := image.DecodeConfig(bufio.NewReader(r))
	if err != nil {
		if errors.Is(err, image.ErrFormat) {
			return 0, 0, UnsupportedReasonFormat
		}
		return 0, 0, UnsupportedReasonCorrupt
	}
	return cfg.Width, cfg.Height, ""
}

// decodeOrientation reads the EXIF Orientation tag, returning 0 (unknown) if
// there is no EXIF data, no Orientation tag, or the file is not a format
// goexif understands (e.g. PNG). This is deliberately lenient: an image
// lacking EXIF is a normal, fully-supported photo, not an error.
func decodeOrientation(r io.Reader) int {
	x, err := exif.Decode(r)
	if err != nil {
		return 0
	}
	tag, err := x.Get(exif.Orientation)
	if err != nil {
		return 0
	}
	v, err := tag.Int(0)
	if err != nil {
		return 0
	}
	if v < 1 || v > 8 {
		return 0
	}
	return v
}

// exifCaptureDate reads EXIF DateTimeOriginal from r, the first and
// preferred rung of the Capture Date fallback chain. It returns ok=false for
// any reason the tag isn't usable (no EXIF, tag absent, unparseable value) -
// callers fall back to the next rung rather than treating this as an error.
//
// Deliberately does NOT use exif.Exif.DateTime(), which silently falls back
// to the plain DateTime tag (time of last save, not capture) - that would
// blur the "which rung produced the value" distinction this ticket requires.
//
// A nonsensical-but-parseable date (e.g. year 1980 sensor default, or a date
// far in the future) is still returned as-is: the ticket requires that a
// photo with a nonsensical embedded date is stored, not rejected. Sanity
// filtering of implausible dates, if ever wanted, belongs in the UI/query
// layer, not here.
// reason is always set when ok is false, so callers can log WHY EXIF yielded
// nothing rather than only observing the fallback rung that was chosen. It is
// empty on success.
func exifCaptureDate(r io.Reader) (t time.Time, ok bool, reason string) {
	x, err := exif.Decode(r)
	if err != nil {
		return time.Time{}, false, "exif decode failed: " + err.Error()
	}
	tag, err := x.Get(exif.DateTimeOriginal)
	if err != nil {
		return time.Time{}, false, "DateTimeOriginal tag absent: " + err.Error()
	}
	str, err := tag.StringVal()
	if err != nil {
		return time.Time{}, false, "DateTimeOriginal value unreadable: " + err.Error()
	}
	str = strings.TrimRight(str, "\x00")

	const exifTimeLayout = "2006:01:02 15:04:05"
	parsed, err := time.ParseInLocation(exifTimeLayout, str, time.UTC)
	if err != nil {
		return time.Time{}, false, "DateTimeOriginal unparseable: " + err.Error()
	}
	return parsed, true, ""
}

// bufferAll reads r fully into memory so metadata extraction can look at the
// same bytes twice (dimensions, then EXIF) without depending on the source
// being seekable itself. File-provider files are not guaranteed to support
// efficient re-reads.
func bufferAll(r io.Reader) (*bytes.Reader, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	return bytes.NewReader(data), nil
}
