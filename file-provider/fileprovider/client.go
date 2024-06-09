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

	return &client{providerId, *logger.GetLogger("fileproviderclient." + providerId), nc, msgApi}
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
	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: OpenFileRequest{
			Name: name,
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
	return &file{c.log, c.nc, c.msgApi, c.providerId, name, resp.FileId}, nil
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
	return &fileInfo{resp}, nil
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
	log        slog.Logger
	nc         *nats.Conn
	msgApi     avro.API
	providerId string
	name       string
	fileId     string
}

func (f *file) Close() error {
	request := FileProviderFileRequest{
		Uid:     uuid.NewString(),
		FileId:  f.fileId,
		Request: FileCloseRequest{},
	}

	response, err := exchangeFile(f.nc, f.msgApi, f.fileId, &request)
	if err != nil {
		f.log.Error("fileClose failed", "uid", request.Uid, "req", request.Request, "error", err)
		return err
	}

	errStr := response.Response.(FileCloseResponse).Error
	if errStr != "" {
		f.log.Error("fileClose failed", "uid", request.Uid, "req", request.Request, "error", errStr)
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

	response, err := exchangeFile(f.nc, f.msgApi, f.fileId, &request)
	if err != nil {
		f.log.Error("fileRead failed", "uid", request.Uid, "req", request.Request, "error", err)
		return 0, err
	}

	resp := response.Response.(FileReadResponse)

	if resp.Error != "" {
		f.log.Error("fileRead failed", "uid", request.Uid, "req", request.Request, "error", resp.Error)
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

	response, err := exchangeFile(f.nc, f.msgApi, f.fileId, &request)
	if err != nil {
		f.log.Error("fileSeek failed", "uid", request.Uid, "req", request.Request, "error", err)
		return -1, err
	}

	resp := response.Response.(FileSeekResponse)
	if resp.Error != "" {
		f.log.Error("fileSeek failed", "uid", request.Uid, "req", request.Request, "error", resp.Error)
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
	sub, _ := f.nc.ChanSubscribe(FileProviderReaddirTopicPrefix+request.Uid, responseChan)

	go readReaddirResponses(f.msgApi, responseChan, readdirChan)

	response, err := exchangeFile(f.nc, f.msgApi, f.fileId, &request)
	if err != nil {
		f.log.Error("readdir failed", "uid", request.Uid, "req", request.Request, "error", err)
		sub.Unsubscribe()
		return nil, err
	}

	fileInfoResponses := <-readdirChan
	sub.Unsubscribe()

	resp := response.Response.(ReaddirResponse)
	if resp.Error != "" {
		f.log.Error("readdir failed", "uid", request.Uid, "req", request.Request, "error", resp.Error)
		return nil, errors.New(resp.Error)
	}
	if fileInfoResponses == nil {
		f.log.Error("readdir failed", "uid", request.Uid, "req", request.Request, "error", "no response within timeout")
	}

	ret := make([]fs.FileInfo, len(fileInfoResponses))
	for i, info := range fileInfoResponses {
		ret[i] = &fileInfo{info}
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

	response, err := exchange(f.nc, f.msgApi, f.providerId, &request)
	if err != nil {
		f.log.Error("stat failed", "uid", request.Uid, "req", request.Request, "error", err)
		return nil, err
	}

	resp := response.Response.(FileInfoResponse)
	if resp.Error != "" {
		f.log.Error("stat failed", "uid", request.Uid, "req", request.Request, "error", resp.Error)
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
