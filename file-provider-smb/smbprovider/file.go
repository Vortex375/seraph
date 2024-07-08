// Copyright © 2024 Benjamin Schmitz

// This file is part of Seraph.

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

package smbprovider

import (
	"context"
	"errors"
	"io"
	"io/fs"
	"os"

	"github.com/hirochachacha/go-smb2"
	"golang.org/x/net/webdav"
)

type smbFile struct {
	fs   *SmbFileSystem
	name string
	flag int
	perm os.FileMode

	offset int64
	file   webdav.File
}

func (f *smbFile) Close() error {
	f.fs.factory.keep()
	return f.file.Close()
}

func (f *smbFile) Read(p []byte) (n int, err error) {
	f.fs.factory.keep()
	n, err = retryFile(f, func() (int, error) {
		return f.file.Read(p)
	})
	if err == nil {
		f.offset += int64(n)
	}
	return
}

func (f *smbFile) Seek(offset int64, whence int) (position int64, err error) {
	f.fs.factory.keep()
	position, err = retryFile(f, func() (int64, error) {
		return f.file.Seek(offset, whence)
	})
	if err == nil {
		f.offset = position
	}
	return
}

func (f *smbFile) Readdir(count int) ([]fs.FileInfo, error) {
	f.fs.factory.keep()
	return retryFile(f, func() ([]fs.FileInfo, error) {
		return f.file.Readdir(count)
	})
}

func (f *smbFile) Stat() (fs.FileInfo, error) {
	f.fs.factory.keep()
	return retryFile(f, func() (fs.FileInfo, error) {
		return f.file.Stat()
	})
}

func (f *smbFile) Write(p []byte) (n int, err error) {
	f.fs.factory.keep()
	n, err = retryFile(f, func() (int, error) {
		return f.file.Write(p)
	})
	if err == nil {
		f.offset += int64(n)
	}
	return
}

func retryFile[T any](f *smbFile, fun func() (T, error)) (T, error) {
	var ret T

	ret, err := fun()
	if errors.Is(err, &smb2.TransportError{}) {
		newFile, err := f.fs.OpenFile(context.Background(), f.name, f.flag, f.perm)
		if err != nil {
			return ret, err
		}
		newFile.Seek(f.offset, io.SeekStart)
		f.file = newFile

		return fun()
	}

	return ret, err
}
