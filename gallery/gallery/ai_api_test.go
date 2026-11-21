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

import "testing"

func TestToPhysicalInvertsTranslate(t *testing.T) {
	folders := []resolvedFolder{
		{providerId: "phys", path: "/mounted/photos/holidays", spaceProviderId: "photos", spacePath: "/holidays"},
		{providerId: "phys2", path: "/", spaceProviderId: "docs", spacePath: "/"},
	}
	cases := []struct {
		sp, spath, wantProvider, wantPath string
		ok                                bool
	}{
		{"photos", "/holidays/sub/a.jpg", "phys", "/mounted/photos/holidays/sub/a.jpg", true},
		{"photos", "/holidays", "phys", "/mounted/photos/holidays", true},
		{"docs", "/a.jpg", "phys2", "/a.jpg", true},
		{"photos", "/other/a.jpg", "", "", false},
		{"photos", "/holidays2/a.jpg", "", "", false},
		{"photos", "/holidays/../secret/a.jpg", "", "", false},
		{"photos", "holidays/a.jpg", "", "", false},
		{"unknown", "/holidays/a.jpg", "", "", false},
	}
	for _, c := range cases {
		pid, p, ok := toPhysical(folders, c.sp, c.spath)
		if ok != c.ok || pid != c.wantProvider || p != c.wantPath {
			t.Errorf("toPhysical(%q, %q) = %q, %q, %v", c.sp, c.spath, pid, p, ok)
		}
		if ok {
			sp, spath, tok := translate(folders, pid, p)
			if !tok || sp != c.sp || spath != c.spath {
				t.Errorf("translate(%q, %q) = %q, %q, %v; want the original", pid, p, sp, spath, tok)
			}
		}
	}
}
