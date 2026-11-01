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

// Package gallerytest holds test-only fixture builders shared by the
// gallery package's internal and external tests: minimal, valid EXIF/TIFF
// byte structures hand-built per TIFF 6.0 / Exif 2.2 (see the docs on
// BuildJPEGWithExifSpec for why there is no EXIF-writing library here).
package gallerytest

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"testing"
)

// This file hand-builds minimal, valid EXIF/TIFF byte structures for test
// fixtures. There is no lightweight, actively-used Go library for WRITING
// EXIF in this repo's dependency set (goexif, used elsewhere for reading, is
// read-only) and pulling in a heavier one (e.g. dsoprea/go-exif) purely to
// synthesize test fixtures was judged not worth the added dependency
// surface. The format is small and stable (TIFF 6.0 / Exif 2.2), so this is
// a bounded, self-contained alternative.

// BuildJPEGWithExif returns JPEG bytes of a solid-colour width x height
// image carrying an EXIF APP1 segment with the given DateTimeOriginal (EXIF
// format "2006:01:02 15:04:05"; empty to omit the tag) and orientation
// (0 to omit the tag).
func BuildJPEGWithExif(t *testing.T, width, height int, dateTimeOriginal string, orientation int) []byte {
	t.Helper()
	return BuildJPEGWithExifSpec(t, width, height, ExifFixtureSpec{
		DateTimeOriginal: dateTimeOriginal,
		Orientation:      orientation,
	})
}

// exifFixtureSpec is everything a fixture JPEG can carry, per sub-IFD.
type ExifFixtureSpec struct {
	DateTimeOriginal   string
	OffsetTimeOriginal string
	Orientation        int

	// GPSDateStamp ("2026:03:08") and GPSTimeStamp as [h, m, s] - written
	// when GpsDateStamp != "".
	GpsDateStamp string
	GpsTimeStamp []int

	// GPS coordinates (decimal degrees); written when GPS is true.
	GPS    bool
	Lat    float64
	Lon    float64
	LatRef string // "N"/"S"
	LonRef string // "E"/"W"
}

func BuildJPEGWithExifSpec(t *testing.T, width, height int, spec ExifFixtureSpec) []byte {
	t.Helper()

	img := image.NewRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			img.Set(x, y, color.RGBA{R: 200, G: 100, B: 50, A: 255})
		}
	}

	var body bytes.Buffer
	if err := jpeg.Encode(&body, img, &jpeg.Options{Quality: 90}); err != nil {
		t.Fatal(err)
	}
	jpegBytes := body.Bytes()

	// jpegBytes starts with SOI (0xFFD8). Splice an APP1/EXIF segment in
	// right after it, exactly where a camera or Go's own encoder would put
	// APP0/APP1.
	if len(jpegBytes) < 2 || jpegBytes[0] != 0xFF || jpegBytes[1] != 0xD8 {
		t.Fatal("encoded JPEG did not start with SOI marker")
	}

	exifSegment := buildExifAPP1Segment(spec)

	out := make([]byte, 0, len(jpegBytes)+len(exifSegment))
	out = append(out, jpegBytes[:2]...) // SOI
	out = append(out, exifSegment...)
	out = append(out, jpegBytes[2:]...)

	return out
}

// buildPNG returns PNG bytes of a solid-colour width x height image. PNG
// carries no EXIF, which is the point: it exercises the "no usable EXIF"
// branch of the Capture Date fallback chain on a genuinely valid,
// decodable image.
func BuildPNG(t *testing.T, width, height int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, width, height))
	for y := 0; y < height; y++ {
		for x := 0; x < width; x++ {
			img.Set(x, y, color.RGBA{R: 10, G: 200, B: 30, A: 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

// buildExifAPP1Segment returns a complete "FF E1 <len> Exif\0\0 <TIFF>" JPEG
// segment built from spec. Layout follows TIFF 6.0 (little-endian) with up
// to three IFDs:
//   - IFD0 holding Orientation (tag 0x0112, SHORT) when set, and pointers
//     to the Exif sub-IFD (0x8769) and the GPS sub-IFD (0x8825) when those
//     carry tags.
//   - one Exif sub-IFD holding DateTimeOriginal (0x9003) and
//     OffsetTimeOriginal (0x9011), both ASCII.
//   - one GPS sub-IFD holding GPSLatitudeRef (0x01), GPSLatitude (0x02),
//     GPSLongitudeRef (0x03), GPSLongitude (0x04), GPSTimeStamp (0x07) and
//     GPSDateStamp (0x1D).
//
// Values that fit in 4 bytes are stored inline; larger values (ASCII
// strings, RATIONAL triples) are appended after all IFDs with their offsets
// backpatched - the same layout real cameras produce.
func buildExifAPP1Segment(spec ExifFixtureSpec) []byte {
	const byteOrderII = "II"
	le := binary.LittleEndian

	type ifdEntry struct {
		tag   uint16
		typ   uint16 // 2=ASCII, 3=SHORT, 4=LONG, 5=RATIONAL
		count uint32
		value []byte // 4 bytes: inline value, or the offset once assigned
	}

	var exifEntries, gpsEntries []ifdEntry

	asciiValue := func(s string) []byte { return append([]byte(s), 0) }
	rationalValue := func(nums ...int) []byte {
		b := make([]byte, 8*len(nums))
		for i, n := range nums {
			le.PutUint32(b[i*8:], uint32(n))
			le.PutUint32(b[i*8+4:], 1)
		}
		return b
	}

	if spec.DateTimeOriginal != "" {
		exifEntries = append(exifEntries, ifdEntry{tag: 0x9003, typ: 2, count: uint32(len(asciiValue(spec.DateTimeOriginal))), value: asciiValue(spec.DateTimeOriginal)})
	}
	if spec.OffsetTimeOriginal != "" {
		exifEntries = append(exifEntries, ifdEntry{tag: 0x9011, typ: 2, count: uint32(len(asciiValue(spec.OffsetTimeOriginal))), value: asciiValue(spec.OffsetTimeOriginal)})
	}

	if spec.GPS || spec.GpsDateStamp != "" {
		gpsEntries = append(gpsEntries, ifdEntry{tag: 0x01, typ: 2, count: 2, value: asciiValue(spec.LatRef)})
		gpsEntries = append(gpsEntries, ifdEntry{tag: 0x03, typ: 2, count: 2, value: asciiValue(spec.LonRef)})
		if spec.GPS {
			gpsEntries = append(gpsEntries, ifdEntry{tag: 0x02, typ: 5, count: 3, value: rationalValue(degreesRational(spec.Lat)...)})
			gpsEntries = append(gpsEntries, ifdEntry{tag: 0x04, typ: 5, count: 3, value: rationalValue(degreesRational(spec.Lon)...)})
		}
		if len(spec.GpsTimeStamp) == 3 {
			gpsEntries = append(gpsEntries, ifdEntry{tag: 0x07, typ: 5, count: 3, value: rationalValue(spec.GpsTimeStamp...)})
		}
		if spec.GpsDateStamp != "" {
			gpsEntries = append(gpsEntries, ifdEntry{tag: 0x1D, typ: 2, count: uint32(len(asciiValue(spec.GpsDateStamp))), value: asciiValue(spec.GpsDateStamp)})
		}
	}

	// entries must be ascending by tag id within an IFD
	sortEntries := func(entries []ifdEntry) {
		for i := 1; i < len(entries); i++ {
			for j := i; j > 0 && entries[j].tag < entries[j-1].tag; j-- {
				entries[j], entries[j-1] = entries[j-1], entries[j]
			}
		}
	}
	sortEntries(exifEntries)
	sortEntries(gpsEntries)

	ifd0 := make([]ifdEntry, 0, 3)
	if spec.Orientation != 0 {
		val := make([]byte, 4)
		le.PutUint16(val[:2], uint16(spec.Orientation))
		ifd0 = append(ifd0, ifdEntry{tag: 0x0112, typ: 3, count: 1, value: val})
	}
	if len(exifEntries) > 0 {
		ifd0 = append(ifd0, ifdEntry{tag: 0x8769, typ: 4, count: 1, value: make([]byte, 4)})
	}
	if len(gpsEntries) > 0 {
		ifd0 = append(ifd0, ifdEntry{tag: 0x8825, typ: 4, count: 1, value: make([]byte, 4)})
	}
	sortEntries(ifd0)

	// An IFD with no entries is simply not written (no pointer, no bytes);
	// sizes must account for that or the extra-data region overlaps the
	// IFDs and every offset lies.
	ifdSize := func(n int) int {
		if n == 0 {
			return 0
		}
		return 2 + 12*n + 4
	}
	ifd0Size := 2 + 12*len(ifd0) + 4 // IFD0 always exists
	exifIFDOffset := 8 + ifd0Size
	gpsIFDOffset := exifIFDOffset + ifdSize(len(exifEntries))
	extraDataOffset := gpsIFDOffset + ifdSize(len(gpsEntries))

	// assign offsets for values that don't fit inline
	var extra bytes.Buffer
	placeValue := func(e *ifdEntry) {
		if len(e.value) <= 4 {
			v := make([]byte, 4)
			copy(v, e.value)
			e.value = v
			return
		}
		off := extraDataOffset + extra.Len()
		v := e.value // the full value, untouched - only the IFD slot gets the offset
		var ob [4]byte
		le.PutUint32(ob[:], uint32(off))
		e.value = ob[:]
		extra.Write(v)
	}
	for i := range ifd0 {
		if ifd0[i].tag == 0x8769 {
			le.PutUint32(ifd0[i].value, uint32(exifIFDOffset))
		}
		if ifd0[i].tag == 0x8825 {
			le.PutUint32(ifd0[i].value, uint32(gpsIFDOffset))
		}
	}
	for i := range exifEntries {
		placeValue(&exifEntries[i])
	}
	for i := range gpsEntries {
		placeValue(&gpsEntries[i])
	}

	// IFD0 is always written (even with zero entries - goexif must see a
	// well-formed empty IFD); an empty sub-IFD is never written and its
	// pointer never exists (see ifdSize's zero case above).
	writeIFD := func(buf *bytes.Buffer, entries []ifdEntry, always bool) {
		if len(entries) == 0 && !always {
			return
		}
		writeU16(buf, le, uint16(len(entries)))
		for _, e := range entries {
			writeU16(buf, le, e.tag)
			writeU16(buf, le, e.typ)
			writeU32(buf, le, e.count)
			buf.Write(e.value)
		}
		writeU32(buf, le, 0) // next IFD = none
	}

	var tiff bytes.Buffer
	tiff.WriteString(byteOrderII)
	writeU16(&tiff, le, 42)
	writeU32(&tiff, le, 8) // IFD0 starts at offset 8

	writeIFD(&tiff, ifd0, true)
	writeIFD(&tiff, exifEntries, false)
	writeIFD(&tiff, gpsEntries, false)
	tiff.Write(extra.Bytes())

	payload := append([]byte("Exif\x00\x00"), tiff.Bytes()...)
	segLen := len(payload) + 2 // + the 2 length bytes themselves

	var seg bytes.Buffer
	seg.WriteByte(0xFF)
	seg.WriteByte(0xE1)
	writeU16BE(&seg, uint16(segLen))
	seg.Write(payload)

	return seg.Bytes()
}

// degreesRational converts a decimal degree into the deg/min/sec triples
// EXIF GPS tags carry, with whole seconds (ample precision for a test).
func degreesRational(deg float64) []int {
	d := int(deg)
	frac := deg - float64(d)
	if frac < 0 {
		frac = -frac
	}
	m := int(frac * 60)
	s := int((frac*60 - float64(m)) * 60)
	return []int{abs(d), m, s}
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

func writeU16(buf *bytes.Buffer, order binary.ByteOrder, v uint16) {
	b := make([]byte, 2)
	order.PutUint16(b, v)
	buf.Write(b)
}

func writeU32(buf *bytes.Buffer, order binary.ByteOrder, v uint32) {
	b := make([]byte, 4)
	order.PutUint32(b, v)
	buf.Write(b)
}

func writeU16BE(buf *bytes.Buffer, v uint16) {
	b := make([]byte, 2)
	binary.BigEndian.PutUint16(b, v)
	buf.Write(b)
}
