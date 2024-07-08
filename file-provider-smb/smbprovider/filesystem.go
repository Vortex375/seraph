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
	"io/fs"
	"os"
	"strings"
	"time"

	"golang.org/x/net/webdav"
	"umbasa.net/seraph/logging"

	"github.com/hirochachacha/go-smb2"
)

type SmbFileSystem struct {
	factory *shareFactory
}

func NewSmbFileSystem(log *logging.Logger, addr string, sharename string, username string, password string) *SmbFileSystem {
	factory := &shareFactory{
		log:       log,
		addr:      addr,
		username:  username,
		password:  password,
		sharename: sharename,
	}

	factory.init()

	return &SmbFileSystem{
		factory: factory,
	}
}

func (smbfs *SmbFileSystem) Close() {
	smbfs.factory.close()
}

func (smbfs *SmbFileSystem) Mkdir(ctx context.Context, name string, perm os.FileMode) error {
	name = strings.TrimPrefix(name, "/")

	return retryVoid(smbfs.factory, func(share *smb2.Share) error {
		return share.Mkdir(name, perm)
	})
}

func (smbfs *SmbFileSystem) OpenFile(ctx context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	name = strings.TrimPrefix(name, "/")

	file, err := retry(smbfs.factory, func(share *smb2.Share) (*smb2.File, error) {
		return share.OpenFile(name, flag, perm)
	})

	if err != nil {
		return nil, err
	}

	return &smbFile{
		fs:     smbfs,
		name:   name,
		flag:   flag,
		perm:   perm,
		offset: 0,
		file:   file,
	}, nil

}

func (smbfs *SmbFileSystem) RemoveAll(ctx context.Context, name string) error {
	name = strings.TrimPrefix(name, "/")

	return retryVoid(smbfs.factory, func(share *smb2.Share) error {
		return share.RemoveAll(name)
	})
}

func (smbfs *SmbFileSystem) Rename(ctx context.Context, oldName string, newName string) error {
	oldName = strings.TrimPrefix(oldName, "/")
	newName = strings.TrimPrefix(newName, "/")

	return retryVoid(smbfs.factory, func(share *smb2.Share) error {
		return share.Rename(oldName, newName)
	})
}

func (smbfs *SmbFileSystem) Stat(ctx context.Context, name string) (fs.FileInfo, error) {
	name = strings.TrimPrefix(name, "/")

	info, err := retry(smbfs.factory, func(share *smb2.Share) (fs.FileInfo, error) {
		return share.Stat(name)
	})

	// it seems some clients abort when failing to stat due to permission
	// they should just show the inaccesible entry instead
	if errors.Is(err, fs.ErrPermission) {
		return &fileInfo{
			name:    name,
			size:    0,
			mode:    0,
			modTime: time.Time{},
		}, nil
	}

	return info, err
}
