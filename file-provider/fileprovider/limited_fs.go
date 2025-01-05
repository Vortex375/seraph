package fileprovider

import (
	"context"
	"io/fs"
	"os"

	"golang.org/x/net/webdav"
)

type LimitedFs struct {
	webdav.FileSystem

	ReadOnly bool
	//TODO: support WriteOnly and NonRecursive modes
}

func (f *LimitedFs) Mkdir(ctx context.Context, name string, perm os.FileMode) error {
	if f.ReadOnly {
		return fs.ErrPermission
	}

	return f.FileSystem.Mkdir(ctx, name, perm)
}

func (f *LimitedFs) OpenFile(ctx context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	if f.ReadOnly {
		flag = os.O_RDONLY
	}
	file, err := f.FileSystem.OpenFile(ctx, name, flag, perm)
	if err != nil {
		return nil, err
	}
	return &limitedFile{
		File:     file,
		readOnly: f.ReadOnly,
	}, nil
}

func (f *LimitedFs) RemoveAll(ctx context.Context, name string) error {
	if f.ReadOnly {
		return fs.ErrPermission
	}

	return f.FileSystem.RemoveAll(ctx, name)
}

func (f *LimitedFs) Rename(ctx context.Context, oldName, newName string) error {
	if f.ReadOnly {
		return fs.ErrPermission
	}

	return f.FileSystem.Rename(ctx, oldName, newName)
}

func (f *LimitedFs) Stat(ctx context.Context, name string) (os.FileInfo, error) {
	return f.FileSystem.Stat(ctx, name)
}

type limitedFile struct {
	webdav.File

	readOnly bool
}

func (f *limitedFile) Close() error {
	return f.File.Close()
}

func (f *limitedFile) Read(p []byte) (int, error) {
	return f.File.Read(p)
}

func (f *limitedFile) Write(p []byte) (int, error) {
	if f.readOnly {
		return 0, fs.ErrPermission
	}
	return f.File.Write(p)
}

func (f *limitedFile) Seek(offset int64, whence int) (int64, error) {
	return f.File.Seek(offset, whence)
}

func (f *limitedFile) Readdir(count int) ([]fs.FileInfo, error) {
	return f.File.Readdir(count)
}

func (f *limitedFile) Stat() (fs.FileInfo, error) {
	return f.File.Stat()
}
