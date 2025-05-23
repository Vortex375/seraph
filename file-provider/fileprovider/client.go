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
	"path"
	"time"

	"github.com/akyoto/cache"
	"github.com/google/uuid"
	"github.com/hamba/avro/v2"
	"github.com/nats-io/nats.go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/trace"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
)

type Client interface {
	webdav.FileSystem

	Close()
}

type client struct {
	providerId string
	log        *slog.Logger
	nc         *nats.Conn
	msgApi     avro.API

	//TODO: replace with centralized cache and event handling
	//for now, this provides a good speedup because Stat() after Readdir() is returned from cache
	fileInfoCache *cache.Cache
}

const defaultTimeout = 30 * time.Second
const cacheTimeout = 5 * time.Second

const maxPayload = 768 * 1024

func exchange(ctx context.Context, nc *nats.Conn, msgApi avro.API, providerId string, request *FileProviderRequest) (*FileProviderResponse, error) {
	tracer := otel.Tracer("fileprovider")
	if tracer != nil {
		var span trace.Span
		ctx, span = tracer.Start(ctx, "exchange")
		defer span.End()
	}

	data, err := msgApi.Marshal(FileProviderRequestSchema, request)
	if err != nil {
		return nil, err
	}

	header := messaging.InjectTraceContext(ctx, make(nats.Header))

	msg, err := nc.RequestMsg(&nats.Msg{
		Subject: FileProviderTopicPrefix + providerId,
		Header:  header,
		Data:    data,
	}, defaultTimeout)
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

func exchangeFile(ctx context.Context, nc *nats.Conn, msgApi avro.API, fileId string, request *FileProviderFileRequest) (*FileProviderFileResponse, error) {
	tracer := otel.Tracer("fileprovider")
	if tracer != nil {
		var span trace.Span
		ctx, span = tracer.Start(ctx, "exchangeFile")
		defer span.End()
	}

	data, err := msgApi.Marshal(FileProviderFileRequestSchema, request)
	if err != nil {
		return nil, err
	}

	header := messaging.InjectTraceContext(ctx, make(nats.Header))

	msg, err := nc.RequestMsg(&nats.Msg{
		Subject: FileProviderFileTopicPrefix + fileId,
		Header:  header,
		Data:    data,
	}, defaultTimeout)
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

func ioError(err IoError) error {
	if err.Error == "" && err.Class == "" {
		return nil
	}
	switch err.Class {
	case "EOF":
		return io.EOF
	case "ErrInvalid":
		return fs.ErrInvalid
	case "ErrPermission":
		return fs.ErrPermission
	case "ErrExist":
		return fs.ErrExist
	case "ErrNotExist":
		return fs.ErrNotExist
	case "ErrClosed":
		return fs.ErrClosed
	default:
		return errors.New(err.Error)
	}
}

func NewFileProviderClient(providerId string, nc *nats.Conn, logger *logging.Logger) Client {
	msgApi := NewMessageApi()

	return &client{
		providerId,
		logger.GetLogger("fileproviderclient." + providerId),
		nc,
		msgApi,
		cache.New(cacheTimeout),
	}
}

func (c *client) Close() {
	c.fileInfoCache.Close()
}

func (c *client) Mkdir(ctx context.Context, name string, perm os.FileMode) error {
	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: MkdirRequest{
			Name: name,
			Perm: perm,
		},
	}

	response, err := exchange(ctx, c.nc, c.msgApi, c.providerId, &request)
	if err != nil {
		c.log.Error("mkdir failed", "uid", request.Uid, "req", request.Request, "error", err)
		return err
	}

	err = ioError(response.Response.(MkdirResponse).Error)
	if err != nil {
		c.log.Error("mkdir failed", "uid", request.Uid, "req", request.Request, "error", err)
		return err
	}
	return nil
}

func (c *client) OpenFile(ctx context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	return &lazyFile{
		client: c,
		ctx:    ctx,
		name:   name,
		flag:   flag,
		perm:   perm,
		file:   nil,
	}, nil
}

func (c *client) doOpenFile(ctx context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: OpenFileRequest{
			Name: name,
			Flag: flag,
			Perm: perm,
		},
	}

	response, err := exchange(ctx, c.nc, c.msgApi, c.providerId, &request)
	if err != nil {
		c.log.Error("openFile failed", "uid", request.Uid, "req", request.Request, "error", err)
		return nil, err
	}

	resp := response.Response.(OpenFileResponse)
	err = ioError(resp.Error)

	if err != nil {
		c.log.Error("openFile failed", "uid", request.Uid, "req", request.Request, "error", err)
		return nil, err
	}
	return &file{
			c:      c,
			ctx:    ctx,
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

	response, err := exchange(ctx, c.nc, c.msgApi, c.providerId, &request)
	if err != nil {
		c.log.Error("removeAll failed", "uid", request.Uid, "req", request.Request, "error", err)
		return err
	}

	err = ioError(response.Response.(RemoveAllResponse).Error)
	if err != nil {
		c.log.Error("removeAll failed", "uid", request.Uid, "req", request.Request, "error", err)
		return err
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

	response, err := exchange(ctx, c.nc, c.msgApi, c.providerId, &request)
	if err != nil {
		c.log.Error("rename failed", "uid", request.Uid, "req", request.Request, "error", err)
		return err
	}

	err = ioError(response.Response.(RenameResponse).Error)
	if err != nil {
		c.log.Error("rename failed", "uid", request.Uid, "req", request.Request, "error", err)
		return err
	}
	return nil
}

func (c *client) Stat(ctx context.Context, name string) (os.FileInfo, error) {
	fromCache, found := c.fileInfoCache.Get(name)
	if found {
		c.log.Debug("returning from cache", "name", name)
		return fromCache.(os.FileInfo), nil
	} else {
		c.log.Debug("not found in cache", "name", name)
	}

	request := FileProviderRequest{
		Uid: uuid.NewString(),
		Request: StatRequest{
			Name: name,
		},
	}

	response, err := exchange(ctx, c.nc, c.msgApi, c.providerId, &request)
	if err != nil {
		c.log.Error("stat failed", "uid", request.Uid, "req", request.Request, "error", err)
		return nil, err
	}

	resp := response.Response.(FileInfoResponse)
	err = ioError(resp.Error)

	if err != nil {
		c.log.Error("stat failed", "uid", request.Uid, "req", request.Request, "error", err)
		return nil, err
	}

	fileInfo := &fileInfo{resp}

	c.log.Debug("caching", "name", name)
	c.fileInfoCache.Set(name, fileInfo, cacheTimeout)

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
	ctx    context.Context
	fileId string
	name   string
}

func (f *file) Close() error {
	request := FileProviderFileRequest{
		Uid:     uuid.NewString(),
		FileId:  f.fileId,
		Request: FileCloseRequest{},
	}

	response, err := exchangeFile(f.ctx, f.c.nc, f.c.msgApi, f.fileId, &request)
	if err != nil {
		f.c.log.Error("fileClose failed", "uid", request.Uid, "req", request.Request, "error", err)
		return err
	}

	err = ioError(response.Response.(FileCloseResponse).Error)
	if err != nil {
		f.c.log.Error("fileClose failed", "uid", request.Uid, "req", request.Request, "error", err)
		return err
	}
	return nil
}

func (f *file) Read(p []byte) (n int, err error) {
	if len(p) <= maxPayload {
		return f.doRead(p)
	}

	offset := 0
	read := 0
	for read < len(p) {
		w, err := f.doRead(p[offset:min(offset+maxPayload, len(p))])
		read += w
		if err != nil {
			return read, err
		}
		offset += w
	}
	return read, nil
}

func (f *file) doRead(p []byte) (n int, err error) {
	request := FileProviderFileRequest{
		Uid:    uuid.NewString(),
		FileId: f.fileId,
		Request: FileReadRequest{
			Len: uint32(len(p)),
		},
	}

	response, err := exchangeFile(f.ctx, f.c.nc, f.c.msgApi, f.fileId, &request)
	if err != nil {
		f.c.log.Error("fileRead failed", "uid", request.Uid, "req", request.Request, "error", err)
		return 0, err
	}

	resp := response.Response.(FileReadResponse)
	err = ioError(resp.Error)

	if err != nil && !errors.Is(err, io.EOF) {
		f.c.log.Error("fileRead failed", "uid", request.Uid, "req", request.Request, "error", err)
		return 0, err
	}

	copy(p, resp.Payload[:min(len(resp.Payload), len(p))])

	return len(resp.Payload), err
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

	response, err := exchangeFile(f.ctx, f.c.nc, f.c.msgApi, f.fileId, &request)
	if err != nil {
		f.c.log.Error("fileSeek failed", "uid", request.Uid, "req", request.Request, "error", err)
		return -1, err
	}

	resp := response.Response.(FileSeekResponse)
	err = ioError(resp.Error)
	if err != nil {
		f.c.log.Error("fileSeek failed", "uid", request.Uid, "req", request.Request, "error", err)
		return -1, err
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

	response, err := exchangeFile(f.ctx, f.c.nc, f.c.msgApi, f.fileId, &request)
	if err != nil {
		f.c.log.Error("readdir failed", "uid", request.Uid, "req", request.Request, "error", err)
		return nil, err
	}

	resp := response.Response.(ReaddirResponse)
	err = ioError(resp.Error)
	if err != nil {
		f.c.log.Error("readdir failed", "uid", request.Uid, "req", request.Request, "error", err)
		return nil, err
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
			filePath := path.Join(f.name, ret[i].Name())
			f.c.log.Debug("caching", "name", filePath)
			f.c.fileInfoCache.Set(filePath, ret[i], cacheTimeout)
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

	response, err := exchange(f.ctx, f.c.nc, f.c.msgApi, f.c.providerId, &request)
	if err != nil {
		f.c.log.Error("stat failed", "uid", request.Uid, "req", request.Request, "error", err)
		return nil, err
	}

	resp := response.Response.(FileInfoResponse)
	err = ioError(resp.Error)
	if err != nil {
		f.c.log.Error("stat failed", "uid", request.Uid, "req", request.Request, "error", err)
		return nil, err
	}
	return &fileInfo{resp}, nil
}

func (f *file) Write(p []byte) (n int, err error) {
	if len(p) <= maxPayload {
		return f.doWrite(p)
	}
	offset := 0
	written := 0
	for written < len(p) {
		w, err := f.doWrite(p[offset:min(offset+maxPayload, len(p))])
		written += w
		if err != nil {
			return written, err
		}
		offset += w
	}
	return written, nil
}

func (f *file) doWrite(p []byte) (n int, err error) {
	request := FileProviderFileRequest{
		Uid:    uuid.NewString(),
		FileId: f.fileId,
		Request: FileWriteRequest{
			Payload: p,
		},
	}

	response, err := exchangeFile(f.ctx, f.c.nc, f.c.msgApi, f.fileId, &request)
	if err != nil {
		f.c.log.Error("fileWrite failed", "uid", request.Uid, "fileId", request.FileId, "error", err)
		return 0, err
	}

	resp := response.Response.(FileWriteResponse)
	err = ioError(resp.Error)

	if err != nil {
		f.c.log.Error("fileWrite failed", "uid", request.Uid, "fileId", request.FileId, "error", err)
		return 0, err
	}

	return resp.Len, nil
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
	ctx    context.Context
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
	return f.client.Stat(f.ctx, f.name)
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
	file, err := f.client.doOpenFile(f.ctx, f.name, f.flag, f.perm)
	if err == nil {
		f.file = file
	}
	return err
}
