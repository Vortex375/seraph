package fileprovider_test

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"testing"

	"github.com/stretchr/testify/assert"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/file-provider/fileprovider"
)

func TestLimitedFs(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "seraph-fileprovider-test-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	testfile, err := os.Create(filepath.Join(tmpDir, "testfile"))
	if err != nil {
		t.Fatal(err)
	}
	testfile.Close()

	dir := webdav.Dir(tmpDir)

	t.Run("TestReadOnly", func(t *testing.T) {
		lfs := &fileprovider.LimitedFs{
			FileSystem: dir,
			ReadOnly:   true,
		}

		t.Run("TestMkdir", func(t *testing.T) {
			err := lfs.Mkdir(context.Background(), "testdir", 0o777)

			assert.ErrorIs(t, err, fs.ErrPermission)
		})

		t.Run("TestRemoveAll", func(t *testing.T) {
			err := lfs.RemoveAll(context.Background(), "testdir")

			assert.ErrorIs(t, err, fs.ErrPermission)
		})

		t.Run("TestRename", func(t *testing.T) {
			err := lfs.Rename(context.Background(), "testdir", "testdir2")

			assert.ErrorIs(t, err, fs.ErrPermission)
		})

		t.Run("TestStat", func(t *testing.T) {
			fileInfo, err := lfs.Stat(context.Background(), "testfile")

			assert.Nil(t, err)
			assert.Equal(t, "testfile", fileInfo.Name())
		})
	})

	t.Run("TestNoLimit", func(t *testing.T) {
		lfs := &fileprovider.LimitedFs{
			FileSystem: dir,
		}

		t.Run("TestMkdir", func(t *testing.T) {
			err := lfs.Mkdir(context.Background(), "testdir", 0o777)

			assert.Nil(t, err)
		})

		t.Run("TestRename", func(t *testing.T) {
			err := lfs.Rename(context.Background(), "testdir", "testdir2")

			assert.Nil(t, err)
		})

		t.Run("TestRemoveAll", func(t *testing.T) {
			err := lfs.RemoveAll(context.Background(), "testdir2")

			assert.Nil(t, err)
		})

		t.Run("TestStat", func(t *testing.T) {
			fileInfo, err := lfs.Stat(context.Background(), "testfile")

			assert.Nil(t, err)
			assert.Equal(t, "testfile", fileInfo.Name())
		})
	})
}
