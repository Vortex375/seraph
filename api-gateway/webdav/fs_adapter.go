// Copyright © 2025 Benjamin Schmitz

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

package webdav

import (
	"context"
	"io/fs"
	"os"
	"path"

	"golang.org/x/net/webdav"
)

// Returns the provided [webdav.FileSystem] as [fs.FS]
func AsFs(ctx context.Context, fs webdav.FileSystem, pathPrefix string) fs.FS {
	return &fsAdapter{ctx, fs, pathPrefix}
}

type fsAdapter struct {
	ctx        context.Context
	fs         webdav.FileSystem
	pathPrefix string
}

type fileAdapter struct {
	webdav.File
}

type dirEntryAdapter struct {
	fileInfo fs.FileInfo
}

func (f *fsAdapter) Open(name string) (fs.File, error) {
	p := path.Join(f.pathPrefix, name)
	file, err := f.fs.OpenFile(f.ctx, p, os.O_RDONLY, 0)
	if err != nil {
		return nil, err
	}
	return &fileAdapter{file}, nil
}

func (f *fileAdapter) ReadDir(n int) ([]fs.DirEntry, error) {
	fileInfos, err := f.Readdir(n)
	if err != nil {
		return nil, err
	}
	dirEntries := make([]fs.DirEntry, 0, len(fileInfos))
	for _, fileInfo := range fileInfos {
		dirEntries = append(dirEntries, &dirEntryAdapter{fileInfo})
	}
	return dirEntries, nil
}

func (d *dirEntryAdapter) Name() string {
	return d.fileInfo.Name()
}

func (d *dirEntryAdapter) IsDir() bool {
	return d.fileInfo.IsDir()
}

func (d *dirEntryAdapter) Type() fs.FileMode {
	return d.fileInfo.Mode()
}

func (d *dirEntryAdapter) Info() (fs.FileInfo, error) {
	return d.fileInfo, nil
}
