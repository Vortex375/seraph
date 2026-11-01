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
	"bytes"
	"testing"
	"time"

	"umbasa.net/seraph/events"
	"umbasa.net/seraph/gallery/gallery/gallerytest"
)

// The capture-time rule (ADR 0003): EXIF DateTimeOriginal is a wall-clock
// time with no zone; CapturedAt is stored as a TRUE instant and
// CapturedAtOffset carries the UTC offset at the place of capture, resolved
// from the photo itself (OffsetTimeOriginal, then the GPS timestamp, then
// floating). These tests exercise that resolution against hand-built EXIF
// fixture JPEGs (see package gallerytest).

func TestCaptureTimeWithOffsetTimeOriginal(t *testing.T) {
	// 14:00 wall time, camera zone +02:00 -> 12:00 UTC, offset +7200
	data := gallerytest.BuildJPEGWithExifSpec(t, 8, 6, gallerytest.ExifFixtureSpec{
		DateTimeOriginal:   "2026:03:08 14:00:00",
		OffsetTimeOriginal: "+02:00",
	})

	capturedAt, offset, source, reason := resolveCaptureDate(bytes.NewReader(data), &events.FileChangedEvent{})
	if source != CaptureDateSourceExif {
		t.Fatalf("source: got %q, want %q (reason %q)", source, CaptureDateSourceExif, reason)
	}
	if offset == nil || *offset != 7200 {
		t.Fatalf("offset: got %v, want 7200", offset)
	}
	want := time.Date(2026, 3, 8, 12, 0, 0, 0, time.UTC).Unix()
	if capturedAt != want {
		t.Fatalf("capturedAt: got %d (%s), want %d (12:00 UTC)", capturedAt, time.Unix(capturedAt, 0).UTC(), want)
	}
}

func TestCaptureTimeWithNegativeOffsetTimeOriginal(t *testing.T) {
	data := gallerytest.BuildJPEGWithExifSpec(t, 8, 6, gallerytest.ExifFixtureSpec{
		DateTimeOriginal:   "2026:03:08 08:30:00",
		OffsetTimeOriginal: "-05:30",
	})

	capturedAt, offset, source, _ := resolveCaptureDate(bytes.NewReader(data), &events.FileChangedEvent{})
	if source != CaptureDateSourceExif {
		t.Fatalf("source: got %q", source)
	}
	if offset == nil || *offset != -19800 {
		t.Fatalf("offset: got %v, want -19800", offset)
	}
	want := time.Date(2026, 3, 8, 14, 0, 0, 0, time.UTC).Unix()
	if capturedAt != want {
		t.Fatalf("capturedAt: got %d, want %d", capturedAt, want)
	}
}

func TestCaptureTimeOffsetFromGpsTimestamp(t *testing.T) {
	// wall 14:00, GPS says the shutter fired at 12:00 UTC -> +02:00
	data := gallerytest.BuildJPEGWithExifSpec(t, 8, 6, gallerytest.ExifFixtureSpec{
		DateTimeOriginal: "2026:03:08 14:00:00",
		GpsDateStamp:     "2026:03:08",
		GpsTimeStamp:     []int{12, 0, 0},
	})

	capturedAt, offset, source, _ := resolveCaptureDate(bytes.NewReader(data), &events.FileChangedEvent{})
	if source != CaptureDateSourceExif {
		t.Fatalf("source: got %q", source)
	}
	if offset == nil || *offset != 7200 {
		t.Fatalf("offset: got %v, want 7200", offset)
	}
	want := time.Date(2026, 3, 8, 12, 0, 0, 0, time.UTC).Unix()
	if capturedAt != want {
		t.Fatalf("capturedAt: got %d, want %d", capturedAt, want)
	}
}

func TestCaptureTimeGpsOffsetRoundsToQuarterHour(t *testing.T) {
	// wall 14:07, GPS 12:00 UTC -> 7 min off, rounds to +02:00
	data := gallerytest.BuildJPEGWithExifSpec(t, 8, 6, gallerytest.ExifFixtureSpec{
		DateTimeOriginal: "2026:03:08 14:07:00",
		GpsDateStamp:     "2026:03:08",
		GpsTimeStamp:     []int{12, 0, 0},
	})

	_, offset, _, _ := resolveCaptureDate(bytes.NewReader(data), &events.FileChangedEvent{})
	if offset == nil || *offset != 7200 {
		t.Fatalf("offset: got %v, want 7200 (rounded to 15 min)", offset)
	}
}

func TestCaptureTimeGpsOffsetBeyondFourteenHoursIsRejected(t *testing.T) {
	// wall 23:00, GPS 02:00 UTC -> a 21 h "offset": no real zone, reject
	// and store floating
	data := gallerytest.BuildJPEGWithExifSpec(t, 8, 6, gallerytest.ExifFixtureSpec{
		DateTimeOriginal: "2026:03:08 23:00:00",
		GpsDateStamp:     "2026:03:08",
		GpsTimeStamp:     []int{2, 0, 0},
	})

	capturedAt, offset, _, _ := resolveCaptureDate(bytes.NewReader(data), &events.FileChangedEvent{})
	if offset == nil || *offset != 0 {
		t.Fatalf("offset: got %v, want floating 0", offset)
	}
	want := time.Date(2026, 3, 8, 23, 0, 0, 0, time.UTC).Unix()
	if capturedAt != want {
		t.Fatalf("capturedAt: got %d, want the wall time as UTC (%d)", capturedAt, want)
	}
}

func TestCaptureTimeFloatingWhenNoOffsetSignal(t *testing.T) {
	data := gallerytest.BuildJPEGWithExifSpec(t, 8, 6, gallerytest.ExifFixtureSpec{
		DateTimeOriginal: "2026:03:08 14:00:00",
	})

	capturedAt, offset, source, _ := resolveCaptureDate(bytes.NewReader(data), &events.FileChangedEvent{})
	if source != CaptureDateSourceExif {
		t.Fatalf("source: got %q", source)
	}
	if offset == nil || *offset != 0 {
		t.Fatalf("offset: got %v, want floating 0", offset)
	}
	want := time.Date(2026, 3, 8, 14, 0, 0, 0, time.UTC).Unix()
	if capturedAt != want {
		t.Fatalf("capturedAt: got %d, want the wall time as UTC (%d)", capturedAt, want)
	}
}

func TestCaptureTimeFallbackRungsCarryNoOffset(t *testing.T) {
	// no EXIF at all (PNG), modTime present -> rung two, offset nil
	data := gallerytest.BuildPNG(t, 4, 4)
	ev := &events.FileChangedEvent{ModTime: 1700000000}

	capturedAt, offset, source, _ := resolveCaptureDate(bytes.NewReader(data), ev)
	if source != CaptureDateSourceModTime {
		t.Fatalf("source: got %q, want %q", source, CaptureDateSourceModTime)
	}
	if capturedAt != 1700000000 {
		t.Fatalf("capturedAt: got %d, want the modTime", capturedAt)
	}
	if offset != nil {
		t.Fatalf("offset: got %v, want nil (modTime is a true instant)", offset)
	}

	// no modTime either -> indexed rung, offset nil
	capturedAt, offset, source, _ = resolveCaptureDate(bytes.NewReader(data), &events.FileChangedEvent{})
	if source != CaptureDateSourceIndexed {
		t.Fatalf("source: got %q, want %q", source, CaptureDateSourceIndexed)
	}
	if offset != nil {
		t.Fatalf("offset: got %v, want nil (indexed is a true instant)", offset)
	}
	if capturedAt == 0 {
		t.Fatal("indexed rung must produce a real timestamp")
	}
}

func TestParseOffsetTime(t *testing.T) {
	cases := []struct {
		in   string
		want int
		ok   bool
	}{
		{"+00:00", 0, true},
		{"+02:00", 7200, true},
		{"-05:30", -19800, true},
		{"+05:45", 20700, true},
		{"+14:00", 50400, true},
		{"-14:00", -50400, true},
		{"+25:00", 0, false},
		{"02:00", 0, false},
		{"+2:00", 0, false},
		{"+02:0a", 0, false},
		{"", 0, false},
	}
	for _, c := range cases {
		got, err := parseOffsetTime(c.in)
		if c.ok && (err != nil || got != c.want) {
			t.Errorf("parseOffsetTime(%q): got %d, %v; want %d, nil", c.in, got, err, c.want)
		}
		if !c.ok && err == nil {
			t.Errorf("parseOffsetTime(%q): expected an error", c.in)
		}
	}
}

// ---- GPS coordinates (ticket 04's extraction half) ----

func TestExtractLocationFromGps(t *testing.T) {
	data := gallerytest.BuildJPEGWithExifSpec(t, 8, 6, gallerytest.ExifFixtureSpec{
		GPS:    true,
		Lat:    38.7223,
		Lon:    -9.1393,
		LatRef: "N",
		LonRef: "W",
	})

	lat, lon := extractLocation(bytes.NewReader(data))
	if lat == nil || lon == nil {
		t.Fatalf("expected coordinates, got %v, %v", lat, lon)
	}
	if diff := *lat - 38.7223; diff > 0.001 || diff < -0.001 {
		t.Errorf("lat: got %f, want ~38.7223", *lat)
	}
	if diff := *lon + 9.1393; diff > 0.001 || diff < -0.001 {
		t.Errorf("lon: got %f, want ~-9.1393", *lon)
	}
}

func TestExtractLocationTreatsZeroZeroAsAbsent(t *testing.T) {
	data := gallerytest.BuildJPEGWithExifSpec(t, 8, 6, gallerytest.ExifFixtureSpec{
		GPS:    true,
		Lat:    0,
		Lon:    0,
		LatRef: "N",
		LonRef: "E",
	})

	lat, lon := extractLocation(bytes.NewReader(data))
	if lat != nil || lon != nil {
		t.Fatalf("(0,0) must count as no fix, got %v, %v", lat, lon)
	}
}

func TestExtractLocationAbsentWithoutGps(t *testing.T) {
	data := gallerytest.BuildJPEGWithExifSpec(t, 8, 6, gallerytest.ExifFixtureSpec{
		DateTimeOriginal: "2026:03:08 14:00:00",
	})
	lat, lon := extractLocation(bytes.NewReader(data))
	if lat != nil || lon != nil {
		t.Fatalf("expected no coordinates, got %v, %v", lat, lon)
	}

	lat, lon = extractLocation(bytes.NewReader(gallerytest.BuildPNG(t, 4, 4)))
	if lat != nil || lon != nil {
		t.Fatalf("PNG has no EXIF: expected no coordinates, got %v, %v", lat, lon)
	}
}

func TestExtractMetadataCarriesLocation(t *testing.T) {
	data := gallerytest.BuildJPEGWithExifSpec(t, 8, 6, gallerytest.ExifFixtureSpec{
		GPS:    true,
		Lat:    48.8584,
		Lon:    2.2945,
		LatRef: "N",
		LonRef: "E",
	})

	meta := extractMetadata(bytes.NewReader(data))
	if meta.Lat == nil || meta.Lon == nil {
		t.Fatalf("expected coordinates on photoMetadata, got %+v", meta)
	}
	if meta.Width != 8 || meta.Height != 6 {
		t.Errorf("dimensions lost: %+v", meta)
	}
}
