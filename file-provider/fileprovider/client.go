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

package fileprovider

import (
	"context"
	"errors"
	"io/fs"
	"log/slog"
	"os"
	"time"

	"github.com/akyoto/cache"
	"github.com/google/uuid"
	"github.com/hamba/avro/v2"
	"github.com/nats-io/nats.go"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/logging"
)

type Client interface {
	webdav.FileSystem
}

type client struct {
	providerId string
	log        slog.Logger
	nc         *nats.Conn
	msgApi     avro.API

	//TODO: replace with centralized cache and event handling
	fileInfoCache *cache.Cache
}

const defaultTimeout = 30 * time.Second

func exchange(nc *nats.Conn, msgApi avro.API, providerId string, request *FileProviderRequest) (*FileProviderResponse, error) {
	data, err := msgApi.Marshal(FileProviderRequestSchema, request)
	if err != nil {
		return nil, err
	}

	msg, err := nc.Request(FileProviderTopicPrefix+providerId, data, defaultTimeout)
	if err != nil {
		return nil, err
	}

	response := FileProviderResponse{}

	err = msgApi.Unmarshal(FileProviderResponseSchema, msg.Data, &response)
	if err != nil {
		return nil, err
	}

	return &response, nil
}

func exchangeFile(nc *nats.Conn, msgApi avro.API, fileId string, request *FileProviderFileRequest) (*FileProviderFileResponse, error) {
	data, err := msgApi.Marshal(FileProviderFileRequestSchema, request)
	if err != nil {
		return nil, err
	}

	msg, err := nc.Request(FileProviderFileTopicPrefix+fileId, data, defaultTimeout)
	if err != nil {
		return nil, err
	}

	response := FileProviderFileResponse{}

	err = msgApi.Unmarshal(FileProviderFileResponseSchema, msg.Data, &response)
	if err != nil {
		return nil, err
	}

	return &response, nil
}

func NewFileProviderClient(providerId string, nc *nats.Conn, logger *logging.Logger) Client {
	msgApi := NewMessageApi()

	return &client{
		providerId,
		*logger.GetLogger("fileproviderclient." + providerId),
		nc,
		msgApi,
		cache.New(defaultTimeout),
	}
}

func (c *client) Mkdir(ctx context.Context, name string, perm os.FileMode) error {
	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: MkdirRequest{
			Name: name,
			Perm: perm,
		},
	}

	response, err := exchange(c.nc, c.msgApi, c.providerId, &request)
	if err != nil {
		c.log.Error("mkdir failed", "uid", request.Uid, "req", request.Request, "error", err)
		return err
	}

	errStr := response.Response.(MkdirResponse).Error
	if errStr != "" {
		c.log.Error("mkdir failed", "uid", request.Uid, "req", request.Request, "error", errStr)
		return errors.New(errStr)
	}
	return nil
}

func (c *client) OpenFile(ctx context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	return &lazyFile{
		client: c,
		name:   name,
		flag:   flag,
		perm:   perm,
		file:   nil,
	}, nil
}

func (c *client) doOpenFile(name string, flag int, perm os.FileMode) (webdav.File, error) {
	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: OpenFileRequest{
			Name: name,
			Flag: flag,
			Perm: perm,
		},
	}

	response, err := exchange(c.nc, c.msgApi, c.providerId, &request)
	if err != nil {
		c.log.Error("openFile failed", "uid", request.Uid, "req", request.Request, "error", err)
		return nil, err
	}

	resp := response.Response.(OpenFileResponse)

	if resp.Error != "" {
		c.log.Error("openFile failed", "uid", request.Uid, "req", request.Request, "error", resp.Error)
		return nil, errors.New(resp.Error)
	}
	return &file{
			c:      c,
			name:   name,
			fileId: resp.FileId},
		nil
}

func (c *client) RemoveAll(ctx context.Context, name string) error {
	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: RemoveAllRequest{
			Name: name,
		},
	}

	response, err := exchange(c.nc, c.msgApi, c.providerId, &request)
	if err != nil {
		c.log.Error("removeAll failed", "uid", request.Uid, "req", request.Request, "error", err)
		return err
	}

	errStr := response.Response.(RemoveAllResponse).Error
	if errStr != "" {
		c.log.Error("removeAll failed", "uid", request.Uid, "req", request.Request, "error", errStr)
		return errors.New(errStr)
	}
	return nil
}

func (c *client) Rename(ctx context.Context, oldName string, newName string) error {
	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: RenameRequest{
			OldName: oldName,
			NewName: newName,
		},
	}

	response, err := exchange(c.nc, c.msgApi, c.providerId, &request)
	if err != nil {
		c.log.Error("rename failed", "uid", request.Uid, "req", request.Request, "error", err)
		return err
	}

	errStr := response.Response.(RenameResponse).Error
	if errStr != "" {
		c.log.Error("rename failed", "uid", request.Uid, "req", request.Request, "error", errStr)
		return errors.New(errStr)
	}
	return nil
}

func (c *client) Stat(ctx context.Context, name string) (os.FileInfo, error) {
	fromCache, found := c.fileInfoCache.Get(name)
	if found {
		return fromCache.(os.FileInfo), nil
	}

	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: StatRequest{
			Name: name,
		},
	}

	response, err := exchange(c.nc, c.msgApi, c.providerId, &request)
	if err != nil {
		c.log.Error("stat failed", "uid", request.Uid, "req", request.Request, "error", err)
		return nil, err
	}

	resp := response.Response.(FileInfoResponse)

	if resp.Error != "" {
		c.log.Error("stat failed", "uid", request.Uid, "req", request.Request, "error", resp.Error)
		return nil, errors.New(resp.Error)
	}

	fileInfo := &fileInfo{resp}

	c.fileInfoCache.Set(name, fileInfo, defaultTimeout)

	return fileInfo, nil
}

type fileInfo struct {
	i FileInfoResponse
}

func (f *fileInfo) Name() string {
	return f.i.Name
}

func (f *fileInfo) Size() int64 {
	return f.i.Size
}

func (f *fileInfo) Mode() fs.FileMode {
	return f.i.Mode
}

func (f *fileInfo) ModTime() time.Time {
	return time.Unix(f.i.ModTime, 0)
}

func (f *fileInfo) IsDir() bool {
	return f.i.IsDir
}

func (f *fileInfo) Sys() any {
	return nil
}

type file struct {
	c      *client
	fileId string
	name   string
}

func (f *file) Close() error {
	request := FileProviderFileRequest{
		Uid:     uuid.NewString(),
		FileId:  f.fileId,
		Request: FileCloseRequest{},
	}

	response, err := exchangeFile(f.c.nc, f.c.msgApi, f.fileId, &request)
	if err != nil {
		f.c.log.Error("fileClose failed", "uid", request.Uid, "req", request.Request, "error", err)
		return err
	}

	errStr := response.Response.(FileCloseResponse).Error
	if errStr != "" {
		f.c.log.Error("fileClose failed", "uid", request.Uid, "req", request.Request, "error", errStr)
		return errors.New(errStr)
	}
	return nil
}

func (f *file) Read(p []byte) (n int, err error) {
	//TODO: max payload
	request := FileProviderFileRequest{
		Uid:    uuid.NewString(),
		FileId: f.fileId,
		Request: FileReadRequest{
			Len: uint32(len(p)),
		},
	}

	response, err := exchangeFile(f.c.nc, f.c.msgApi, f.fileId, &request)
	if err != nil {
		f.c.log.Error("fileRead failed", "uid", request.Uid, "req", request.Request, "error", err)
		return 0, err
	}

	resp := response.Response.(FileReadResponse)

	if resp.Error != "" {
		f.c.log.Error("fileRead failed", "uid", request.Uid, "req", request.Request, "error", resp.Error)
		return 0, errors.New(resp.Error)
	}

	copy(p, resp.Payload[:min(len(resp.Payload), len(p))])

	return len(resp.Payload), nil
}

func (f *file) Seek(offset int64, whence int) (int64, error) {
	request := FileProviderFileRequest{
		Uid:    uuid.NewString(),
		FileId: f.fileId,
		Request: FileSeekRequest{
			Offset: offset,
			Whence: whence,
		},
	}

	response, err := exchangeFile(f.c.nc, f.c.msgApi, f.fileId, &request)
	if err != nil {
		f.c.log.Error("fileSeek failed", "uid", request.Uid, "req", request.Request, "error", err)
		return -1, err
	}

	resp := response.Response.(FileSeekResponse)
	if resp.Error != "" {
		f.c.log.Error("fileSeek failed", "uid", request.Uid, "req", request.Request, "error", resp.Error)
		return -1, errors.New(resp.Error)
	}
	return resp.Offset, nil
}

func (f *file) Readdir(count int) ([]fs.FileInfo, error) {
	request := FileProviderFileRequest{
		Uid:    uuid.NewString(),
		FileId: f.fileId,
		Request: ReaddirRequest{
			Count: count,
		},
	}

	var chanSize int
	if count > 0 {
		chanSize = count
	} else {
		chanSize = 512 * 1024
	}

	responseChan := make(chan *nats.Msg, chanSize)
	readdirChan := make(chan []FileInfoResponse)
	sub, _ := f.c.nc.ChanSubscribe(FileProviderReaddirTopicPrefix+request.Uid, responseChan)
	defer sub.Unsubscribe()

	go readReaddirResponses(f.c.msgApi, responseChan, readdirChan)

	response, err := exchangeFile(f.c.nc, f.c.msgApi, f.fileId, &request)
	if err != nil {
		f.c.log.Error("readdir failed", "uid", request.Uid, "req", request.Request, "error", err)
		return nil, err
	}

	resp := response.Response.(ReaddirResponse)
	if resp.Error != "" {
		f.c.log.Error("readdir failed", "uid", request.Uid, "req", request.Request, "error", resp.Error)
		return nil, errors.New(resp.Error)
	}

	var ret []fs.FileInfo
	if resp.Count == 0 {
		close(responseChan)
		ret = make([]fs.FileInfo, 0)
	} else {
		fileInfoResponses := <-readdirChan
		if fileInfoResponses == nil {
			f.c.log.Error("readdir failed", "uid", request.Uid, "req", request.Request, "error", "no response within timeout")
		}

		ret = make([]fs.FileInfo, len(fileInfoResponses))
		for i, info := range fileInfoResponses {
			ret[i] = &fileInfo{info}
			f.c.fileInfoCache.Set(ret[i].Name(), ret[i], defaultTimeout)
		}
	}

	return ret, nil
}

func (f *file) Stat() (fs.FileInfo, error) {
	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: StatRequest{
			Name: f.name,
		},
	}

	response, err := exchange(f.c.nc, f.c.msgApi, f.c.providerId, &request)
	if err != nil {
		f.c.log.Error("stat failed", "uid", request.Uid, "req", request.Request, "error", err)
		return nil, err
	}

	resp := response.Response.(FileInfoResponse)
	if resp.Error != "" {
		f.c.log.Error("stat failed", "uid", request.Uid, "req", request.Request, "error", resp.Error)
		return nil, errors.New(resp.Error)
	}
	return &fileInfo{resp}, nil
}

func (f *file) Write(p []byte) (n int, err error) {
	panic("not implemented") // TODO: Implement
}

func readReaddirResponses(msgApi avro.API, responseChan chan *nats.Msg, finalChan chan []FileInfoResponse) {
	fileInfoResponses := make([]FileInfoResponse, 0)
	last := false
	for !last {
		r := FileInfoResponse{}
		m, ok := readWithTimeout(responseChan, defaultTimeout)
		if !ok {
			finalChan <- nil
			return
		}
		if m == nil {
			// directory was empty
			return
		}
		msgApi.Unmarshal(FileInfoResponseSchema, m.Data, &r)
		fileInfoResponses = append(fileInfoResponses, r)
		last = r.Last
	}
	finalChan <- fileInfoResponses
}

func readWithTimeout[T any](c chan T, timeout time.Duration) (T, bool) {
	timer := time.NewTimer(timeout)
	var v T
	select {
	case v = <-c:
		return v, true
	case <-timer.C:
		return v, false
	}
}

type lazyFile struct {
	client *client
	name   string
	flag   int
	perm   os.FileMode
	file   webdav.File
}

func (f *lazyFile) Close() error {
	if f.file != nil {
		ret := f.file.Close()
		f.file = nil
		return ret
	}
	return nil
}

func (f *lazyFile) Read(p []byte) (n int, err error) {
	if f.file == nil {
		err := f.doOpen()
		if err != nil {
			return 0, err
		}

	}

	return f.file.Read(p)
}

func (f *lazyFile) Seek(offset int64, whence int) (int64, error) {
	if f.file == nil {
		err := f.doOpen()
		if err != nil {
			return 0, err
		}
	}

	return f.file.Seek(offset, whence)
}

func (f *lazyFile) Readdir(count int) ([]fs.FileInfo, error) {
	if f.file == nil {
		err := f.doOpen()
		if err != nil {
			return nil, err
		}
	}

	return f.file.Readdir(count)
}

func (f *lazyFile) Stat() (fs.FileInfo, error) {
	// if the file is new, then we must actually open it to do Stat()
	if (f.flag & os.O_CREATE) != 0 {
		if f.file == nil {
			err := f.doOpen()
			if err != nil {
				return nil, err
			}
		}
		return f.file.Stat()
	}
	return f.client.Stat(context.Background(), f.name)
}

func (f *lazyFile) Write(p []byte) (n int, err error) {
	if f.file == nil {
		err := f.doOpen()
		if err != nil {
			return 0, err
		}
	}

	return f.file.Write(p)
}

func (f *lazyFile) doOpen() error {
	file, err := f.client.doOpenFile(f.name, f.flag, f.perm)
	if err == nil {
		f.file = file
	}
	return err
}
