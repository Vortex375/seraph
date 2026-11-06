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

package thumbnailer

import (
	"context"
	"errors"
	"io"
	"os"
	"path"
	"slices"
	"strings"

	"umbasa.net/seraph/audio-metadata/audiometadata"
	"umbasa.net/seraph/file-provider/fileprovider"
)

// Folder cover images, by priority, for audio files without embedded art.
var (
	coverNames      = []string{"cover", "folder", "front", "album"}
	coverExtensions = []string{".jpg", ".jpeg", ".png"}
)

// albumArt returns the picture to thumbnail for the audio file at path: its
// embedded cover (from audio-metadata), else a cover image in the same
// folder. ok is false when path is not an audio file (or audio-metadata is
// not running) or has no art at all.
//
// ponytail: a cached audio Thumbnail is keyed on the audio file only, so
// adding or changing a folder cover does not refresh it. Invalidate the
// folder's audio Thumbnails on cover file changes if stale art becomes a
// real complaint.
func (t *Thumbnailer) albumArt(ctx context.Context, fs fileprovider.Client, providerId string, filePath string) ([]byte, bool) {
	data, _, err := audiometadata.ReadPicture(ctx, t.nc, providerId, filePath)
	var e *audiometadata.Error
	switch {
	case err == nil:
		return data, true
	case !errors.As(err, &e):
		t.log.Debug("audio-metadata unavailable for album art", "path", filePath, "error", err)
		return nil, false
	case e.Class != audiometadata.ErrorClassNoPicture:
		return nil, false // not audio, or unreadable
	}

	coverPath, ok := folderCover(ctx, fs, path.Dir(filePath))
	if !ok {
		return nil, false
	}
	cover, err := fs.OpenFile(ctx, coverPath, os.O_RDONLY, 0)
	if err != nil {
		t.log.Error("error opening folder cover", "path", coverPath, "error", err)
		return nil, false
	}
	defer cover.Close()
	data, err = io.ReadAll(cover)
	if err != nil {
		t.log.Error("error reading folder cover", "path", coverPath, "error", err)
		return nil, false
	}
	return data, true
}

// folderCover finds dir's cover image (case-insensitive, by coverNames
// priority).
func folderCover(ctx context.Context, fs fileprovider.Client, dir string) (string, bool) {
	d, err := fs.OpenFile(ctx, dir, os.O_RDONLY, 0)
	if err != nil {
		return "", false
	}
	defer d.Close()
	infos, err := d.Readdir(-1)
	if err != nil {
		return "", false
	}

	best, bestRank := "", len(coverNames)
	for _, info := range infos {
		if info.IsDir() {
			continue
		}
		name := strings.ToLower(info.Name())
		ext := path.Ext(name)
		if !slices.Contains(coverExtensions, ext) {
			continue
		}
		if rank := slices.Index(coverNames, strings.TrimSuffix(name, ext)); rank >= 0 && rank < bestRank {
			best, bestRank = info.Name(), rank
		}
	}
	return path.Join(dir, best), best != ""
}
