package webdav

import (
	"context"
	"io/fs"
	"os"
	"time"

	"golang.org/x/net/webdav"
	"umbasa.net/seraph/spaces/spaces"
)

type spacesFileSystem struct {
	server *webDavServer
	sp     []spaces.Space
}

var _ webdav.FileSystem = &spacesFileSystem{}

func (f *spacesFileSystem) Mkdir(ctx context.Context, name string, perm os.FileMode) error {
	return fs.ErrPermission
}

func (f *spacesFileSystem) OpenFile(ctx context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	var provider *spaces.SpaceFileProvider
	if name == "" || name == "/" {
		provider = nil
	} else {
		provider = f.findFileProvider(name)
		if provider == nil {
			return nil, fs.ErrNotExist
		}
	}
	return &fileProviderFile{f.server, ctx, f.sp, provider}, nil
}

func (f *spacesFileSystem) RemoveAll(ctx context.Context, name string) error {
	return fs.ErrPermission
}

func (f *spacesFileSystem) Rename(ctx context.Context, oldName, newName string) error {
	return fs.ErrPermission
}

func (f *spacesFileSystem) Stat(ctx context.Context, name string) (os.FileInfo, error) {
	var provider *spaces.SpaceFileProvider
	if name == "" || name == "/" {
		provider = nil
	} else {
		provider = f.findFileProvider(name)
		if provider == nil {
			return nil, fs.ErrNotExist
		}
	}
	return &fileProviderFileInfo{f.sp, provider}, nil
}

func (f *spacesFileSystem) findFileProvider(name string) *spaces.SpaceFileProvider {
	for _, s := range f.sp {
		for _, p := range s.FileProviders {
			if p.SpaceProviderId == name {
				return &p
			}
		}
	}
	return nil
}

type fileProviderFileInfo struct {
	sp       []spaces.Space
	provider *spaces.SpaceFileProvider
}

var _ fs.FileInfo = &fileProviderFileInfo{}

func (f *fileProviderFileInfo) Name() string {
	if f.provider == nil {
		return "/"
	}
	return f.provider.SpaceProviderId
}

func (f *fileProviderFileInfo) Size() int64 {
	return 0
}

func (f *fileProviderFileInfo) Mode() fs.FileMode {
	return 0555
}

func (f *fileProviderFileInfo) ModTime() time.Time {
	return time.Time{}
}

func (f *fileProviderFileInfo) IsDir() bool {
	return true
}

func (f *fileProviderFileInfo) Sys() any {
	return nil
}

type fileProviderFile struct {
	server   *webDavServer
	ctx      context.Context
	sp       []spaces.Space
	provider *spaces.SpaceFileProvider
}

var _ webdav.File = &fileProviderFile{}

func (f *fileProviderFile) Close() error {
	return nil
}

func (f *fileProviderFile) Read(p []byte) (n int, err error) {
	return 0, fs.ErrInvalid
}

func (f *fileProviderFile) Seek(offset int64, whence int) (int64, error) {
	return 0, fs.ErrInvalid
}

func (f *fileProviderFile) Write(p []byte) (n int, err error) {
	return 0, fs.ErrInvalid
}

func (f *fileProviderFile) Readdir(count int) ([]fs.FileInfo, error) {
	if f.provider == nil {
		dirs := make([]fs.FileInfo, 0)
		for _, s := range f.sp {
			for _, p := range s.FileProviders {
				dirs = append(dirs, &fileProviderFileInfo{f.sp, &p})
			}
		}
		return dirs, nil
	}
	client := f.server.getClient(f.provider.ProviderId)
	file, err := client.OpenFile(f.ctx, "/", os.O_RDONLY, 0)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	return file.Readdir(count)
}

func (f *fileProviderFile) Stat() (fs.FileInfo, error) {
	return &fileProviderFileInfo{f.sp, f.provider}, nil
}
