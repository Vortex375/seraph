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

package gallery_test

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

// buildJPEGWithExif returns JPEG bytes of a solid-colour width x height
// image carrying an EXIF APP1 segment with the given DateTimeOriginal (EXIF
// format "2006:01:02 15:04:05"; empty to omit the tag) and orientation
// (0 to omit the tag).
func buildJPEGWithExif(t *testing.T, width, height int, dateTimeOriginal string, orientation int) []byte {
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

	exifSegment := buildExifAPP1Segment(dateTimeOriginal, orientation)

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
func buildPNG(t *testing.T, width, height int) []byte {
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
// segment. Layout follows TIFF 6.0 (little-endian) with:
//   - IFD0 holding Orientation (tag 0x0112, SHORT) when orientation != 0,
//     and an ExifIFD pointer (tag 0x8769, LONG) when dateTimeOriginal != "".
//   - one Exif sub-IFD holding DateTimeOriginal (tag 0x9003, ASCII, 20
//     bytes incl. NUL) when dateTimeOriginal != "".
func buildExifAPP1Segment(dateTimeOriginal string, orientation int) []byte {
	const byteOrderII = "II"
	le := binary.LittleEndian

	var tiff bytes.Buffer
	// TIFF header: byte order, magic 42, offset to IFD0 (right after header)
	tiff.WriteString(byteOrderII)
	writeU16(&tiff, le, 42)
	writeU32(&tiff, le, 8) // IFD0 starts at offset 8

	type ifdEntry struct {
		tag   uint16
		typ   uint16 // 2=ASCII, 3=SHORT, 4=LONG
		count uint32
		value []byte // exactly 4 bytes, inline value or offset
	}

	ifd0 := make([]ifdEntry, 0, 2)
	if orientation != 0 {
		val := make([]byte, 4)
		le.PutUint16(val[:2], uint16(orientation))
		ifd0 = append(ifd0, ifdEntry{tag: 0x0112, typ: 3, count: 1, value: val})
	}

	var exifSubIFDOffsetPlaceholderIdx = -1
	if dateTimeOriginal != "" {
		val := make([]byte, 4) // filled in once we know the sub-IFD's offset
		ifd0 = append(ifd0, ifdEntry{tag: 0x8769, typ: 4, count: 1, value: val})
		exifSubIFDOffsetPlaceholderIdx = len(ifd0) - 1
	}

	// --- lay out IFD0 ---
	ifd0Offset := tiff.Len()
	ifd0Start := ifd0Offset

	// IFD0 entry count
	entryCount := len(ifd0)
	// size of IFD0 block: 2 (count) + 12*entries + 4 (next-IFD offset)
	ifd0Size := 2 + 12*entryCount + 4

	// values that don't fit inline (ASCII strings > 4 bytes) are appended
	// after all IFDs; IFD0 has none in our fixture (Orientation is inline,
	// ExifIFD pointer is inline once resolved), so extraData starts right
	// after IFD0.
	extraDataOffset := ifd0Start + ifd0Size

	// build the Exif sub-IFD bytes separately so we know its size/offset
	var subIFD bytes.Buffer
	subIFDOffset := 0
	if dateTimeOriginal != "" {
		// DateTimeOriginal must be exactly "YYYY:MM:DD HH:MM:SS\0" (20 bytes)
		strVal := dateTimeOriginal
		strBytes := append([]byte(strVal), 0)
		for len(strBytes) < 20 {
			strBytes = append(strBytes, 0)
		}

		subIFDOffset = extraDataOffset
		// the string itself is stored right after the sub-IFD block since it
		// does not fit inline (20 bytes > 4)
		subIFDSize := 2 + 12*1 + 4
		strOffset := subIFDOffset + subIFDSize

		writeU16(&subIFD, le, 1) // 1 entry
		writeU16(&subIFD, le, 0x9003)
		writeU16(&subIFD, le, 2) // ASCII
		writeU32(&subIFD, le, uint32(len(strBytes)))
		offsetBytes := make([]byte, 4)
		le.PutUint32(offsetBytes, uint32(strOffset))
		subIFD.Write(offsetBytes)
		writeU32(&subIFD, le, 0) // next IFD = none

		subIFD.Write(strBytes)

		// now that we know subIFDOffset, backfill the ExifIFD pointer value
		// in ifd0
		le.PutUint32(ifd0[exifSubIFDOffsetPlaceholderIdx].value, uint32(subIFDOffset))
	}

	// --- write IFD0 ---
	writeU16(&tiff, le, uint16(entryCount))
	for _, e := range ifd0 {
		writeU16(&tiff, le, e.tag)
		writeU16(&tiff, le, e.typ)
		writeU32(&tiff, le, e.count)
		tiff.Write(e.value)
	}
	writeU32(&tiff, le, 0) // no IFD1

	// --- append the Exif sub-IFD block (at extraDataOffset) ---
	tiff.Write(subIFD.Bytes())

	// --- wrap in APP1 segment ---
	payload := append([]byte("Exif\x00\x00"), tiff.Bytes()...)
	segLen := len(payload) + 2 // + the 2 length bytes themselves

	var seg bytes.Buffer
	seg.WriteByte(0xFF)
	seg.WriteByte(0xE1)
	writeU16BE(&seg, uint16(segLen))
	seg.Write(payload)

	return seg.Bytes()
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
