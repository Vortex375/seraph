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
	"fmt"
	"image"
	"io"
	"math"
	"strconv"
	"strings"
	"time"

	"github.com/rwcarlsen/goexif/exif"
	"github.com/rwcarlsen/goexif/tiff"

	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
)

// exifTimeLayout is the EXIF date/TimeOriginal ASCII layout.
const exifTimeLayout = "2006:01:02 15:04:05"

// photoMetadata is what metadata extraction produces for one file. It is
// deliberately decoupled from GalleryPhoto so extraction can be tested and
// reasoned about without a database.
type photoMetadata struct {
	// Lat/Lon are the photo's WGS84 coordinates from EXIF GPS, or nil when
	// the photo has none - or has the (0, 0) some cameras write to mean
	// "no fix", which is treated as absent rather than as "middle of the
	// ocean". Altitude, direction and the other GPS tags are not stored.
	Lat *float64
	Lon *float64
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

// extractMetadata decodes pixel dimensions, EXIF orientation and GPS
// coordinates from image bytes. A file that is not a recognized image
// format, or that is truncated or otherwise corrupt, is reported via
// Unsupported rather than as a Go error: callers must still store the item.
//
// r must support Seek back to the start; extractMetadata reads it multiple
// times (via image.DecodeConfig, for EXIF orientation, and again for
// capture time and GPS).
func extractMetadata(r io.ReadSeeker) photoMetadata {
	width, height, unsupported := decodeDimensions(r)
	if unsupported != "" {
		return photoMetadata{Unsupported: unsupported}
	}

	orientation := 0
	if _, err := r.Seek(0, io.SeekStart); err == nil {
		orientation = decodeOrientation(r)
	}

	var lat, lon *float64
	if _, err := r.Seek(0, io.SeekStart); err == nil {
		lat, lon = extractLocation(r)
	}

	return photoMetadata{
		Width:       width,
		Height:      height,
		Orientation: orientation,
		Lat:         lat,
		Lon:         lon,
	}
}

// extractLocation reads the photo's GPS coordinates from EXIF, returning
// nil pointers when the photo has no usable fix: no EXIF, no GPS sub-IFD,
// unparseable values, or the (0, 0) some cameras write to mean "no fix".
// Out-of-range values are treated the same way - garbage coordinates must
// not resolve to a place in the middle of the Gulf of Guinea.
func extractLocation(r io.Reader) (lat, lon *float64) {
	x, err := exif.Decode(r)
	if err != nil {
		return nil, nil
	}
	eLat, eLon, err := x.LatLong()
	if err != nil {
		return nil, nil
	}
	// (0, 0) is "no fix", not "middle of the ocean"
	if eLat == 0 && eLon == 0 {
		return nil, nil
	}
	if eLat < -90 || eLat > 90 || eLon < -180 || eLon > 180 {
		return nil, nil
	}
	return &eLat, &eLon
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
// preferred rung of the Capture Date fallback chain, together with the UTC
// offset at the place of capture where the photo itself records one (see
// resolveExifOffset). It returns ok=false for any reason the tag isn't
// usable (no EXIF, tag absent, unparseable value) - callers fall back to the
// next rung rather than treating this as an error.
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
//
// offset is non-nil whenever the photo itself allowed the capture-time rule
// to determine the offset at the place of capture (including the "floating"
// case: offset 0, wall time stored as if UTC). It is nil only for the
// modTime/indexed rungs, which are true instants carrying no offset - see
// resolveCaptureDate.
func exifCaptureDate(r io.Reader) (t time.Time, offset *int, ok bool, reason string) {
	x, err := exif.Decode(r)
	if err != nil {
		return time.Time{}, nil, false, "exif decode failed: " + err.Error()
	}
	tag, err := x.Get(exif.DateTimeOriginal)
	if err != nil {
		return time.Time{}, nil, false, "DateTimeOriginal tag absent: " + err.Error()
	}
	str, err := tag.StringVal()
	if err != nil {
		return time.Time{}, nil, false, "DateTimeOriginal value unreadable: " + err.Error()
	}
	str = strings.TrimRight(str, "\x00")

	parsed, err := time.ParseInLocation(exifTimeLayout, str, time.UTC)
	if err != nil {
		return time.Time{}, nil, false, "DateTimeOriginal unparseable: " + err.Error()
	}

	off, offReason := resolveExifOffset(x, parsed)
	if offReason != "" {
		// a date without a determinable offset is still a usable Capture
		// Date - it is stored floating (offset 0). The reason is for the
		// log, not a failure.
		reason = offReason
	}
	return parsed, off, true, reason
}

// resolveExifOffset determines the UTC offset (seconds east of UTC) at the
// place of capture from the photo's own EXIF, per the capture-time rule:
//
//  1. EXIF OffsetTimeOriginal (tag 0x9011, "±HH:MM") - the camera knew the
//     zone it was set to. goexif's field map predates EXIF 2.31 and drops
//     unknown tags (LoadTags with showMissing=false), so this one tag is
//     read from the raw EXIF IFD directly rather than switching libraries.
//  2. The GPS timestamp: GPSDateStamp + GPSTimeStamp are UTC by definition,
//     so the offset is the wall time minus that instant, rounded to 15
//     minutes and accepted only within ±14 h (no real zone is further off).
//  3. None: the photo is "floating" - its wall time is stored as if UTC
//     with offset 0, which renders unchanged under the app's display rule.
//
// The returned reason explains WHY no offset was determinable whenever
// offset is the floating 0; it is empty when a real offset was found. It is
// purely for the extraction log.
func resolveExifOffset(x *exif.Exif, wall time.Time) (offset *int, reason string) {
	if s, ok := exifOffsetTimeOriginal(x); ok {
		if off, err := parseOffsetTime(s); err == nil {
			return &off, ""
		} else {
			return floatingOffset(), "OffsetTimeOriginal unparseable: " + err.Error()
		}
	}

	off, ok := gpsOffset(x, wall)
	if ok {
		return &off, ""
	}
	return floatingOffset(), "no OffsetTimeOriginal, no GPS timestamp"
}

// floatingOffset is the "floating" offset: 0 seconds east of UTC. A photo
// whose wall time could not be tied to a zone stores its wall clock as if it
// were UTC, which the app's display rule then renders unchanged.
func floatingOffset() *int {
	zero := 0
	return &zero
}

// exifOffsetTimeOriginal reads tag 0x9011 (OffsetTimeOriginal, "±HH:MM")
// from the raw EXIF sub-IFD. goexif (2019) predates EXIF 2.31 and silently
// drops tags it does not know, so x.Get cannot see this one - but its decode
// keeps the raw TIFF bytes (Exif.Raw) and the sub-IFD pointer is a known
// tag, so the single tag is read directly from the IFD with goexif's own
// tiff parser. No library switch, no second format implementation.
func exifOffsetTimeOriginal(x *exif.Exif) (string, bool) {
	if x.Tiff == nil || len(x.Raw) == 0 {
		return "", false
	}
	ptr, err := x.Get(exif.ExifIFDPointer)
	if err != nil {
		return "", false
	}
	off, err := ptr.Int64(0)
	if err != nil {
		return "", false
	}

	r := bytes.NewReader(x.Raw)
	if _, err := r.Seek(off, io.SeekStart); err != nil {
		return "", false
	}
	dir, _, err := tiff.DecodeDir(r, x.Tiff.Order)
	if err != nil {
		return "", false
	}
	for _, tag := range dir.Tags {
		if tag.Id != offsetTimeOriginalTag {
			continue
		}
		if tag.Format() != tiff.StringVal {
			return "", false
		}
		return strings.TrimRight(string(tag.Val), "\x00"), true
	}
	return "", false
}

// offsetTimeOriginalTag is the EXIF 2.31 OffsetTimeOriginal tag id ("±HH:MM"
// string, the zone the camera clock was set to at capture).
const offsetTimeOriginalTag = 0x9011

// parseOffsetTime parses an EXIF offset string ("±HH:MM") into seconds east
// of UTC. Anything outside ±24 h is rejected as malformed rather than
// trusted.
func parseOffsetTime(s string) (int, error) {
	s = strings.TrimSpace(s)
	if len(s) != 6 || (s[0] != '+' && s[0] != '-') || s[3] != ':' {
		return 0, errors.New("not an EXIF offset string")
	}
	hours, err := strconv.Atoi(s[1:3])
	if err != nil {
		return 0, fmt.Errorf("offset hours: %w", err)
	}
	mins, err := strconv.Atoi(s[4:6])
	if err != nil {
		return 0, fmt.Errorf("offset minutes: %w", err)
	}
	off := hours*3600 + mins*60
	if s[0] == '-' {
		off = -off
	}
	if off > 24*3600 || off < -24*3600 {
		return 0, errors.New("offset out of range")
	}
	return off, nil
}

// gpsOffset derives the capture offset from the GPS timestamp:
// GPSDateStamp + GPSTimeStamp are, by EXIF definition, the UTC instant the
// shutter fired, so the camera's local wall time minus that instant IS the
// offset at the place of capture - wherever the camera's clock was wrong,
// the zone it recorded is still informative only through this difference.
//
// The result is rounded to 15 minutes (zones are whole-quarter-hour offsets
// at worst) and rejected unless within ±14 h, the range of real UTC offsets.
// ok is false when the tags are absent/unparseable or the implied offset
// fails those checks.
func gpsOffset(x *exif.Exif, wall time.Time) (int, bool) {
	dateTag, err := x.Get(exif.GPSDateStamp)
	if err != nil {
		return 0, false
	}
	dateStr, err := dateTag.StringVal()
	if err != nil {
		return 0, false
	}
	dateStr = strings.TrimRight(dateStr, "\x00")
	// GPSDateStamp uses the EXIF date layout with colons, like DateTime.
	gpsDate, err := time.ParseInLocation("2006:01:02", dateStr, time.UTC)
	if err != nil {
		return 0, false
	}

	timeTag, err := x.Get(exif.GPSTimeStamp)
	if err != nil {
		return 0, false
	}
	var gpsClock [3]float64
	for i := 0; i < 3; i++ {
		num, den, err := timeTag.Rat2(i)
		if err != nil {
			return 0, false
		}
		if den == 0 {
			return 0, false
		}
		gpsClock[i] = float64(num) / float64(den)
	}
	gpsUTC := gpsDate.Add(time.Duration(gpsClock[0] * float64(time.Hour))).
		Add(time.Duration(gpsClock[1] * float64(time.Minute))).
		Add(time.Duration(gpsClock[2] * float64(time.Second)))

	diff := wall.Unix() - gpsUTC.Unix()
	// round to the nearest 15 minutes
	rounded := int(math.Round(float64(diff)/900) * 900)
	if rounded > 14*3600 || rounded < -14*3600 {
		return 0, false
	}
	return rounded, true
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
