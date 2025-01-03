package fileprovider

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"go.opentelemetry.io/otel/trace"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/messaging"
)

// force-close files if left idle without calling close()
// TODO: might be too generous
const idleTimeout = 30 * time.Minute

type serverFile struct {
	ctx context.Context

	uid      string
	fileId   uuid.UUID
	fileName string
	file     webdav.File
	server   *FileProviderServer

	requestSub    *nats.Subscription
	requestChan   chan *nats.Msg
	fileClosed    bool
	channelClosed bool
}

func newServerFile(ctx context.Context, uid string, fileId uuid.UUID, fileName string, file webdav.File, server *FileProviderServer) error {
	fileTopic := FileProviderFileTopicPrefix + fileId.String()

	requestChan := make(chan *nats.Msg, nats.DefaultSubPendingMsgsLimit)
	requestSub, err := server.nc.ChanSubscribe(fileTopic, requestChan)
	if err != nil {
		return err
	}

	f := &serverFile{
		ctx:         ctx,
		uid:         uid,
		fileId:      fileId,
		fileName:    fileName,
		file:        file,
		server:      server,
		requestSub:  requestSub,
		requestChan: requestChan,
	}

	// block server.Stop() while there are still files open
	server.wg.Add(1)
	go f.messageLoop()

	return nil
}

func (f *serverFile) messageLoop() {
	defer f.closeFile()
	defer f.server.wg.Done()

	timer := time.NewTimer(idleTimeout)
	for {
		select {
		case msg, ok := <-f.requestChan:
			if !ok {
				return
			}

			timer.Stop()
			timer.Reset(idleTimeout)

			f.handleMessage(msg)

		// stop accepting new requests when timeout expired
		// or context is canceled (on server shutdown)
		// f.requestChan will be closed
		// which will cause us to return from this loop
		// closing the file if it was still open
		case <-timer.C:
			f.closeChannel()
		case <-f.ctx.Done():
			f.closeChannel()
		}
	}
}

func (f *serverFile) handleMessage(msg *nats.Msg) {
	ctx := messaging.ExtractTraceContext(f.ctx, msg)
	request := FileProviderFileRequest{}
	f.server.msgApi.Unmarshal(FileProviderFileRequestSchema, msg.Data, &request)

	response := f.handleRequest(ctx, &request)
	data, _ := f.server.msgApi.Marshal(FileProviderFileResponseSchema, response)
	msg.Respond(data)
}

func (f *serverFile) handleRequest(ctx context.Context, request *FileProviderFileRequest) *FileProviderFileResponse {
	switch fileReq := request.Request.(type) {
	case FileCloseRequest:
		return f.handleClose(ctx, request.Uid, request.FileId, &fileReq)
	case FileReadRequest:
		return f.handleRead(ctx, request.Uid, request.FileId, &fileReq)
	case FileWriteRequest:
		return f.handleWrite(ctx, request.Uid, request.FileId, &fileReq)
	case FileSeekRequest:
		return f.handleSeek(ctx, request.Uid, request.FileId, &fileReq)
	case ReaddirRequest:
		return f.handleReaddir(ctx, request.Uid, request.FileId, &fileReq)
	}
	return &FileProviderFileResponse{}
}

func (f *serverFile) handleClose(ctx context.Context, uid string, fileId string, req *FileCloseRequest) *FileProviderFileResponse {
	var span trace.Span
	ctx, span = f.server.tracer.Start(ctx, "close")
	defer span.End()

	// close communication after file closed
	defer f.closeChannel()

	err := f.closeFile()
	if err == nil {
		f.server.log.Debug("fileClose", "uid", uid, "fileId", fileId)
	} else {
		f.server.log.Error("fileClose failed", "uid", uid, "fileId", fileId, "error", err)
	}

	return &FileProviderFileResponse{
		Uid: uid,
		Response: FileCloseResponse{
			Error: toIoError(err),
		},
	}
}

func (f *serverFile) handleRead(ctx context.Context, uid string, fileId string, req *FileReadRequest) *FileProviderFileResponse {
	var span trace.Span
	ctx, span = f.server.tracer.Start(ctx, "read")
	defer span.End()

	if req.Len > maxPayload {
		err := fmt.Errorf("read exceeds max payload of %d", maxPayload)
		f.server.log.Error("fileRead failed", "uid", uid, "fileId", fileId, "error", err)
		return &FileProviderFileResponse{
			Uid: uid,
			Response: FileReadResponse{
				Error: toIoError(err),
			},
		}
	}

	buf := make([]byte, req.Len)
	len, err := f.file.Read(buf)
	if err == nil || errors.Is(err, io.EOF) {
		f.server.log.Debug("fileRead", "uid", uid, "fileId", fileId)
	} else {
		f.server.log.Error("fileRead failed", "uid", uid, "fileId", fileId, "error", err)
	}

	fileResponse := FileReadResponse{}
	if err == nil {
		fileResponse.Payload = buf[0:len]
	} else {
		fileResponse.Error = toIoError(err)
	}

	return &FileProviderFileResponse{
		Uid:      uid,
		Response: fileResponse,
	}
}

func (f *serverFile) handleWrite(ctx context.Context, uid string, fileId string, req *FileWriteRequest) *FileProviderFileResponse {
	var span trace.Span
	ctx, span = f.server.tracer.Start(ctx, "write")
	defer span.End()

	if f.server.readOnly {
		return &FileProviderFileResponse{
			Uid: uid,
			Response: FileWriteResponse{
				Error: IoError{"read only", "ErrPermission"},
			},
		}
	}

	len, err := f.file.Write(req.Payload)
	if err == nil {
		f.server.log.Debug("fileWrite", "uid", uid, "fileId", fileId)
	} else {
		f.server.log.Error("fileWrite failed", "uid", uid, "fileId", fileId, "error", err)
	}

	return &FileProviderFileResponse{
		Uid: uid,
		Response: FileWriteResponse{
			Len:   len,
			Error: toIoError(err),
		},
	}
}

func (f *serverFile) handleSeek(ctx context.Context, uid string, fileId string, req *FileSeekRequest) *FileProviderFileResponse {
	var span trace.Span
	ctx, span = f.server.tracer.Start(ctx, "seek")
	defer span.End()

	offset, err := f.file.Seek(req.Offset, req.Whence)
	if err == nil {
		f.server.log.Debug("fileSeek", "uid", uid, "fileId", fileId)
	} else {
		f.server.log.Error("fileSeek failed", "uid", uid, "fileId", fileId, "error", err)
	}

	return &FileProviderFileResponse{
		Uid: uid,
		Response: FileSeekResponse{
			Offset: offset,
			Error:  toIoError(err),
		},
	}
}

func (f *serverFile) handleReaddir(ctx context.Context, uid string, fileId string, req *ReaddirRequest) *FileProviderFileResponse {
	var span trace.Span
	ctx, span = f.server.tracer.Start(ctx, "readdir")
	defer span.End()

	fileInfos, err := f.file.Readdir(req.Count)
	if err == nil {
		f.server.log.Debug("readdir", "uid", uid, "fileId", fileId)
	} else {
		f.server.log.Error("readdir failed", "uid", uid, "fileId", fileId, "error", err)
	}

	if err == nil {
		for i, fileInfo := range fileInfos {
			fileInfoResponse := FileInfoResponse{
				Name:    fileInfo.Name(),
				IsDir:   fileInfo.IsDir(),
				Size:    fileInfo.Size(),
				Mode:    fileInfo.Mode(),
				ModTime: fileInfo.ModTime().Unix(),
				Last:    i == len(fileInfos)-1,
			}
			fileInfoResponseData, e := f.server.msgApi.Marshal(FileInfoResponseSchema, &fileInfoResponse)
			if e != nil {
				err = e
				break
			}
			e = f.server.nc.Publish(FileProviderReaddirTopicPrefix+uid, fileInfoResponseData)
			if e != nil {
				err = e
				break
			}

			var readdir *events.ReadDir
			if req.Count <= 0 || len(fileInfos) < req.Count {
				// if it lists the entire directory
				readdir = &events.ReadDir{
					Readdir: uid,
					Index:   int64(i),
					Total:   int64(len(fileInfos)),
				}
			} else {
				// partial readdir is not published as readdir
				readdir = nil
			}

			f.server.publishFileInfoEvent(ctx, f.fileName+"/"+fileInfo.Name(), fileInfo, readdir)
		}
	}

	if err == nil {
		return &FileProviderFileResponse{
			Uid: uid,
			Response: ReaddirResponse{
				Count: len(fileInfos),
			},
		}
	} else {
		return &FileProviderFileResponse{
			Uid: uid,
			Response: ReaddirResponse{
				Error: toIoError(err),
			},
		}
	}
}

func (f *serverFile) closeChannel() {
	if !f.channelClosed {
		f.requestSub.Unsubscribe()
		close(f.requestChan)
		f.channelClosed = true
	}
}

func (f *serverFile) closeFile() (err error) {
	if !f.fileClosed {
		err = f.file.Close()
		f.fileClosed = true
	}
	return
}
