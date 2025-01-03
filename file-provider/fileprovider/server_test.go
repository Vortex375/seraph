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

package fileprovider

import (
	"context"
	"errors"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/hamba/avro/v2"
	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/mock"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/tracing"
)

type MockFileSystem struct {
	mock.Mock
}

func (fs *MockFileSystem) Mkdir(ctx context.Context, name string, perm os.FileMode) error {
	args := fs.Called(ctx, name, perm)
	return args.Error(0)
}

func (fs *MockFileSystem) OpenFile(ctx context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	args := fs.Called(ctx, name, flag, perm)
	return args.Get(0).(webdav.File), args.Error(1)
}

func (fs *MockFileSystem) RemoveAll(ctx context.Context, name string) error {
	args := fs.Called(ctx, name)
	return args.Error(0)
}

func (fs *MockFileSystem) Rename(ctx context.Context, oldName string, newName string) error {
	args := fs.Called(ctx, oldName, newName)
	return args.Error(0)
}

func (fs *MockFileSystem) Stat(ctx context.Context, name string) (os.FileInfo, error) {
	args := fs.Called(ctx, name)
	return args.Get(0).(os.FileInfo), args.Error(1)
}

type MockFileInfo struct {
	name    string
	size    int64
	mode    fs.FileMode
	modTime time.Time
	isDir   bool
}

func (i *MockFileInfo) Name() string {
	return i.name
}

func (i *MockFileInfo) Size() int64 {
	return i.size
}

func (i *MockFileInfo) Mode() fs.FileMode {
	return i.mode
}

func (i *MockFileInfo) ModTime() time.Time {
	return i.modTime
}

func (i *MockFileInfo) IsDir() bool {
	return i.isDir
}

func (i *MockFileInfo) Sys() any {
	return nil
}

type MockFile struct {
	mock.Mock
}

func (f *MockFile) Close() error {
	args := f.Called()
	return args.Error(0)
}

func (f *MockFile) Read(p []byte) (n int, err error) {
	args := f.Called(p)
	return args.Int(0), args.Error(1)
}

func (f *MockFile) Seek(offset int64, whence int) (int64, error) {
	args := f.Called(offset, whence)
	return args.Get(0).(int64), args.Error(1)
}

func (f *MockFile) Write(p []byte) (n int, err error) {
	args := f.Called(p)
	return args.Int(0), args.Error(1)
}

func (f *MockFile) Readdir(count int) ([]fs.FileInfo, error) {
	args := f.Called(count)
	return args.Get(0).([]fs.FileInfo), args.Error(1)
}

func (f *MockFile) Stat() (fs.FileInfo, error) {
	args := f.Called()
	return args.Get(0).(fs.FileInfo), args.Error(1)
}

var natsServer *server.Server
var tmpDir string

func TestMain(m *testing.M) {
	setup()

	code := m.Run()

	shutdown()

	os.Exit(code)
}

func setup() {
	opts := &server.Options{}
	var err error
	natsServer, err = server.NewServer(opts)
	if err != nil {
		panic(err)
	}

	natsServer.Start()

	tmpDir, err = os.MkdirTemp("", "seraph-fileprovider-test-")
	if err != nil {
		panic(err)
	}
}

func shutdown() {
	if natsServer != nil {
		natsServer.Shutdown()
		natsServer = nil
	}
	if tmpDir != "" {
		os.RemoveAll(tmpDir)
	}
}

func getServer(t *testing.T, fs webdav.FileSystem, readOnly bool) (*FileProviderServer, *nats.Conn) {
	nc, err := nats.Connect(natsServer.ClientURL())
	if err != nil {
		t.Fatal(err)
	}
	logger := logging.New(logging.Params{})
	logger.SetLevel(slog.LevelDebug)

	params := ServerParams{
		Logger:  logger,
		Tracing: tracing.NewNoopTracing(),
		Nc:      nc,
		Js:      nil,
	}

	server, err := NewFileProviderServer(params, "testprovider", fs, readOnly)
	if err != nil {
		t.Fatal(err)
	}

	return server, nc
}

func TestMkdir(t *testing.T) {
	mockFs := MockFileSystem{}

	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: MkdirRequest{
			Name: "testdir",
			Perm: 0644,
		},
	}

	expected := FileProviderResponse{
		Uid: request.Uid,
		Response: MkdirResponse{
			Error: IoError{},
		},
	}

	mockFs.On("Mkdir", mock.Anything, "testdir", fs.FileMode(0644)).Return(nil)

	doTest(t, &mockFs, false, request, responseEquals(expected))
}

func TestMkdirError(t *testing.T) {
	mockFs := MockFileSystem{}

	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: MkdirRequest{
			Name: "testdir",
			Perm: 0644,
		},
	}

	expected := FileProviderResponse{
		Uid: request.Uid,
		Response: MkdirResponse{
			Error: IoError{Error: "request failed"},
		},
	}

	mockFs.On("Mkdir", mock.Anything, "testdir", fs.FileMode(0644)).Return(errors.New("request failed"))

	doTest(t, &mockFs, false, request, responseEquals(expected))
}

func TestMkdirReadOnly(t *testing.T) {
	mockFs := MockFileSystem{}

	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: MkdirRequest{
			Name: "testdir",
			Perm: 0644,
		},
	}

	expected := FileProviderResponse{
		Uid: request.Uid,
		Response: MkdirResponse{
			Error: IoError{"read only", "ErrPermission"},
		},
	}

	doTest(t, &mockFs, true, request, responseEquals(expected))
}

func TestRemoveAll(t *testing.T) {
	mockFs := MockFileSystem{}

	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: RemoveAllRequest{
			Name: "testdir",
		},
	}

	expected := FileProviderResponse{
		Uid: request.Uid,
		Response: RemoveAllResponse{
			Error: IoError{},
		},
	}

	mockFs.On("RemoveAll", mock.Anything, "testdir").Return(nil)

	doTest(t, &mockFs, false, request, responseEquals(expected))
}

func TestRemoveAllError(t *testing.T) {
	mockFs := MockFileSystem{}

	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: RemoveAllRequest{
			Name: "testdir",
		},
	}

	expected := FileProviderResponse{
		Uid: request.Uid,
		Response: RemoveAllResponse{
			Error: IoError{Error: "removeAll failed"},
		},
	}

	mockFs.On("RemoveAll", mock.Anything, "testdir").Return(errors.New("removeAll failed"))

	doTest(t, &mockFs, false, request, responseEquals(expected))
}

func TestRemoveAllReadOnly(t *testing.T) {
	mockFs := MockFileSystem{}

	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: RemoveAllRequest{
			Name: "testdir",
		},
	}

	expected := FileProviderResponse{
		Uid: request.Uid,
		Response: RemoveAllResponse{
			Error: IoError{"read only", "ErrPermission"},
		},
	}

	doTest(t, &mockFs, true, request, responseEquals(expected))
}

func TestRename(t *testing.T) {
	mockFs := MockFileSystem{}

	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: RenameRequest{
			OldName: "foo",
			NewName: "bar",
		},
	}

	expected := FileProviderResponse{
		Uid: request.Uid,
		Response: RenameResponse{
			Error: IoError{},
		},
	}

	mockFs.On("Rename", mock.Anything, "foo", "bar").Return(nil)

	doTest(t, &mockFs, false, request, responseEquals(expected))
}

func TestRenameError(t *testing.T) {
	mockFs := MockFileSystem{}

	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: RenameRequest{
			OldName: "foo",
			NewName: "bar",
		},
	}

	expected := FileProviderResponse{
		Uid: request.Uid,
		Response: RenameResponse{
			Error: IoError{Error: "rename failed"},
		},
	}

	mockFs.On("Rename", mock.Anything, "foo", "bar").Return(errors.New("rename failed"))

	doTest(t, &mockFs, false, request, responseEquals(expected))
}

func TestRenameReadOnly(t *testing.T) {
	mockFs := MockFileSystem{}

	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: RenameRequest{
			OldName: "foo",
			NewName: "bar",
		},
	}

	expected := FileProviderResponse{
		Uid: request.Uid,
		Response: RenameResponse{
			Error: IoError{"read only", "ErrPermission"},
		},
	}

	doTest(t, &mockFs, true, request, responseEquals(expected))
}

func TestStat(t *testing.T) {
	mockFs := MockFileSystem{}

	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: StatRequest{
			Name: "testfile",
		},
	}

	ts := time.Now()

	expected := FileProviderResponse{
		Uid: request.Uid,
		Response: FileInfoResponse{
			Name:    "testfile",
			Size:    123,
			Mode:    fs.ModeDir,
			ModTime: ts.Unix(),
			IsDir:   true,
		},
	}

	mockFs.On("Stat", mock.Anything, "testfile").Return(&MockFileInfo{
		name:    "testfile",
		size:    123,
		mode:    fs.ModeDir,
		modTime: ts,
		isDir:   true,
	}, nil)

	doTest(t, &mockFs, false, request, responseEquals(expected))
}

func TestStatError(t *testing.T) {
	mockFs := MockFileSystem{}

	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: StatRequest{
			Name: "testfile",
		},
	}

	expected := FileProviderResponse{
		Uid: request.Uid,
		Response: FileInfoResponse{
			Error: IoError{Error: "stat failed"},
		},
	}

	var null *MockFileInfo = nil
	mockFs.On("Stat", mock.Anything, "testfile").Return(null, errors.New("stat failed"))

	doTest(t, &mockFs, false, request, responseEquals(expected))
}

func TestOpenFile(t *testing.T) {
	mockFs := MockFileSystem{}

	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: OpenFileRequest{
			Name: "testfile",
			Flag: os.O_CREATE,
			Perm: 0444,
		},
	}

	var null *os.File = nil
	mockFs.On("OpenFile", mock.Anything, "testfile", os.O_CREATE, fs.FileMode(0444)).Return(null, nil)

	doTest(t, &mockFs, false, request, func(t *testing.T, actual FileProviderResponse) {
		assert.IsType(t, OpenFileResponse{}, actual.Response)
		openFileResponse := actual.Response.(OpenFileResponse)
		assert.NotEmpty(t, openFileResponse.FileId)
		assert.Empty(t, openFileResponse.Error)
	})
}

func TestOpenFileError(t *testing.T) {
	mockFs := MockFileSystem{}

	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: OpenFileRequest{
			Name: "testfile",
			Flag: os.O_CREATE,
			Perm: 0444,
		},
	}

	var null *os.File = nil
	mockFs.On("OpenFile", mock.Anything, "testfile", os.O_CREATE, fs.FileMode(0444)).Return(null, errors.New("open file failed"))

	doTest(t, &mockFs, false, request, func(t *testing.T, actual FileProviderResponse) {
		assert.IsType(t, OpenFileResponse{}, actual.Response)
		openFileResponse := actual.Response.(OpenFileResponse)
		assert.Empty(t, openFileResponse.FileId)
		assert.Equal(t, IoError{Error: "open file failed"}, openFileResponse.Error)
	})
}

func TestOpenFileReadOnly(t *testing.T) {
	mockFs := MockFileSystem{}

	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: OpenFileRequest{
			Name: "testfile",
			Flag: os.O_CREATE,
			Perm: 0444,
		},
	}

	var null *os.File = nil
	mockFs.On("OpenFile", mock.Anything, "testfile", os.O_RDONLY, fs.FileMode(0444)).Return(null, nil)

	doTest(t, &mockFs, true, request, func(t *testing.T, actual FileProviderResponse) {
		assert.IsType(t, OpenFileResponse{}, actual.Response)
		openFileResponse := actual.Response.(OpenFileResponse)
		assert.NotEmpty(t, openFileResponse.FileId)
		assert.Empty(t, openFileResponse.Error)
	})
}

func TestFile(t *testing.T) {
	mockFs := MockFileSystem{}
	testServer, nc := getServer(t, &mockFs, false)
	msgApi := NewMessageApi()
	testServer.Start()
	defer testServer.Stop(true)
	defer nc.Close()

	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: OpenFileRequest{
			Name: "testfile",
			Flag: os.O_CREATE,
			Perm: 0444,
		},
	}

	mockFile := MockFile{}
	mockFs.On("OpenFile", mock.Anything, "testfile", os.O_CREATE, fs.FileMode(0444)).Return(&mockFile, nil)

	data, _ := msgApi.Marshal(FileProviderRequestSchema, &request)
	msg, err := nc.Request(FileProviderTopicPrefix+testServer.providerId, data, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}

	response := FileProviderResponse{}
	msgApi.Unmarshal(FileProviderResponseSchema, msg.Data, &response)
	fileId := response.Response.(OpenFileResponse).FileId

	t.Run("FileRead", func(t *testing.T) {
		fileRequest := FileProviderFileRequest{
			Uid:    uuid.NewString(),
			FileId: fileId,
			Request: FileReadRequest{
				Len: 5,
			},
		}

		mockFile.On("Read", mock.Anything).Run(func(args mock.Arguments) {
			assert.IsType(t, make([]byte, 0), args.Get(0))
			buf := args.Get(0).([]byte)
			assert.Equal(t, 5, len(buf))
			for i := range buf {
				buf[i] = byte(i)
			}
		}).Return(5, nil)

		expected := FileProviderFileResponse{
			Uid: fileRequest.Uid,
			Response: FileReadResponse{
				Payload: []byte{0, 1, 2, 3, 4},
			},
		}

		doFileTest(t, nc, msgApi, fileId, &mockFile, fileRequest, fileResponseEquals(expected))
	})

	t.Run("FileWrite", func(t *testing.T) {
		payload := []byte{1, 2, 3, 4, 5}
		fileRequest := FileProviderFileRequest{
			Uid:    uuid.NewString(),
			FileId: fileId,
			Request: FileWriteRequest{
				Payload: payload,
			},
		}

		mockFile.On("Write", payload).Return(len(payload), nil)

		expected := FileProviderFileResponse{
			Uid: fileRequest.Uid,
			Response: FileWriteResponse{
				Len: len(payload),
			},
		}

		doFileTest(t, nc, msgApi, fileId, &mockFile, fileRequest, fileResponseEquals(expected))
	})

	t.Run("FileSeek", func(t *testing.T) {
		offset := 123
		whence := io.SeekCurrent
		fileRequest := FileProviderFileRequest{
			Uid:    uuid.NewString(),
			FileId: fileId,
			Request: FileSeekRequest{
				Offset: int64(offset),
				Whence: whence,
			},
		}

		mockFile.On("Seek", int64(offset), whence).Return(int64(offset), nil)

		expected := FileProviderFileResponse{
			Uid: fileRequest.Uid,
			Response: FileSeekResponse{
				Offset: int64(123),
			},
		}

		doFileTest(t, nc, msgApi, fileId, &mockFile, fileRequest, fileResponseEquals(expected))
	})

	t.Run("Readdir", func(t *testing.T) {
		fileRequest := FileProviderFileRequest{
			Uid:    uuid.NewString(),
			FileId: fileId,
			Request: ReaddirRequest{
				Count: 10,
			},
		}

		ts := time.Now()
		mockFile.On("Readdir", 10).Return([]fs.FileInfo{
			&MockFileInfo{
				name:    "testfile1",
				size:    123,
				mode:    fs.ModeDir,
				modTime: ts,
				isDir:   true,
			},
			&MockFileInfo{
				name:    "testfile2",
				size:    456,
				mode:    fs.ModeDir,
				modTime: ts,
				isDir:   true,
			},
			&MockFileInfo{
				name:    "testfile3",
				size:    789,
				mode:    fs.ModeSymlink,
				modTime: ts,
				isDir:   false,
			},
		}, nil)

		expected := FileProviderFileResponse{
			Uid: fileRequest.Uid,
			Response: ReaddirResponse{
				Count: 3,
			},
		}

		expectedFileInfo := []FileInfoResponse{
			{
				Name:    "testfile1",
				Size:    123,
				Mode:    fs.ModeDir,
				ModTime: ts.Unix(),
				IsDir:   true,
				Last:    false,
			},
			{
				Name:    "testfile2",
				Size:    456,
				Mode:    fs.ModeDir,
				ModTime: ts.Unix(),
				IsDir:   true,
				Last:    false,
			},
			{
				Name:    "testfile3",
				Size:    789,
				Mode:    fs.ModeSymlink,
				ModTime: ts.Unix(),
				IsDir:   false,
				Last:    true,
			},
		}

		responseChan := make(chan *nats.Msg, 3)
		readdirChan := make(chan []FileInfoResponse)
		sub, _ := nc.ChanSubscribe(FileProviderReaddirTopicPrefix+fileRequest.Uid, responseChan)
		go readReaddirResponses(msgApi, responseChan, readdirChan)

		doFileTest(t, nc, msgApi, fileId, &mockFile, fileRequest, fileResponseEquals(expected))

		fileInfoResponses := <-readdirChan

		if fileInfoResponses == nil {
			t.Fatal("did not receive readdir responses")
		}

		sub.Unsubscribe()
		assert.Equal(t, expectedFileInfo, fileInfoResponses)
	})

	// FileClose must be run last or the other tests will fail
	t.Run("FileClose", func(t *testing.T) {
		fileRequest := FileProviderFileRequest{
			Uid:     uuid.NewString(),
			FileId:  fileId,
			Request: FileCloseRequest{},
		}

		mockFile.On("Close").Return(nil)

		expected := FileProviderFileResponse{
			Uid:      fileRequest.Uid,
			Response: FileCloseResponse{},
		}

		doFileTest(t, nc, msgApi, fileId, &mockFile, fileRequest, fileResponseEquals(expected))
	})
}

func doTest(t *testing.T, mockFs *MockFileSystem, readOnly bool, request FileProviderRequest, expectation func(*testing.T, FileProviderResponse)) {
	testServer, nc := getServer(t, mockFs, readOnly)
	msgApi := NewMessageApi()
	testServer.Start()
	defer testServer.Stop(true)
	defer nc.Close()

	data, _ := msgApi.Marshal(FileProviderRequestSchema, &request)
	msg, err := nc.Request(FileProviderTopicPrefix+testServer.providerId, data, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}

	mockFs.AssertExpectations(t)

	actual := FileProviderResponse{}

	msgApi.Unmarshal(FileProviderResponseSchema, msg.Data, &actual)

	expectation(t, actual)
}

func doFileTest(t *testing.T, nc *nats.Conn, msgApi avro.API, fileId string, mockFile *MockFile, fileRequest FileProviderFileRequest, expectation func(*testing.T, FileProviderFileResponse)) {
	fileData, err := msgApi.Marshal(FileProviderFileRequestSchema, fileRequest)
	if err != nil {
		t.Fatal(err)
	}
	fileMsg, err := nc.Request(FileProviderFileTopicPrefix+fileId, fileData, 5*time.Hour)
	if err != nil {
		t.Fatal(err)
	}

	mockFile.AssertExpectations(t)

	actual := FileProviderFileResponse{}

	msgApi.Unmarshal(FileProviderFileResponseSchema, fileMsg.Data, &actual)

	expectation(t, actual)
}

func responseEquals(expected FileProviderResponse) func(*testing.T, FileProviderResponse) {
	return func(t *testing.T, actual FileProviderResponse) {
		assert.Equal(t, expected, actual)
	}
}

func fileResponseEquals(expected FileProviderFileResponse) func(*testing.T, FileProviderFileResponse) {
	return func(t *testing.T, actual FileProviderFileResponse) {
		assert.Equal(t, expected, actual)
	}
}

// func buffered[T any](in chan T) chan T {
// 	out := make(chan T)
// 	buffer := make([]T, 0)

// 	go func() {
// 		defer close(out)
// 		for {
// 			if len(buffer) == 0 {
// 				item, ok := <-in
// 				if !ok {
// 					return
// 				}
// 				buffer = append(buffer, item)
// 				continue
// 			}
// 			select {
// 			case item, ok := <-in:
// 				if ok {
// 					buffer = append(buffer, item)
// 				} else {
// 					for _, item := range buffer {
// 						out <- item
// 					}
// 					return
// 				}
// 			case out <- buffer[0]:
// 				buffer = buffer[1:]
// 			}
// 		}
// 	}()

// 	return out
// }
