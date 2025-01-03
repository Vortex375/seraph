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
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"os"
	"strings"
	"sync"

	"github.com/google/uuid"
	"github.com/hamba/avro/v2"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/fx"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/tracing"
)

type FileProviderServer struct {
	providerId string
	readOnly   bool

	log    *slog.Logger
	tracer trace.Tracer
	nc     *nats.Conn
	msgApi avro.API
	fs     webdav.FileSystem

	requestSub  *nats.Subscription
	requestChan chan *nats.Msg
	wg          sync.WaitGroup
	ctx         context.Context
	cancel      context.CancelFunc
}

type ServerParams struct {
	fx.In

	Nc      *nats.Conn
	Js      jetstream.JetStream
	Logger  *logging.Logger
	Tracing *tracing.Tracing
}

func toIoError(err error) IoError {
	if err == nil {
		return IoError{}
	}
	if errors.Is(err, io.EOF) {
		return IoError{err.Error(), "EOF"}
	}
	if errors.Is(err, fs.ErrInvalid) {
		return IoError{err.Error(), "ErrInvalid"}
	}
	if errors.Is(err, fs.ErrPermission) {
		return IoError{err.Error(), "ErrPermission"}
	}
	if errors.Is(err, fs.ErrExist) {
		return IoError{err.Error(), "ErrExist"}
	}
	if errors.Is(err, fs.ErrNotExist) {
		return IoError{err.Error(), "ErrNotExist"}
	}
	if errors.Is(err, fs.ErrClosed) {
		return IoError{err.Error(), "ErrClosed"}
	}
	return IoError{Error: err.Error()}
}

func NewFileProviderServer(p ServerParams, providerId string, fileSystem webdav.FileSystem, readOnly bool) (*FileProviderServer, error) {
	log := p.Logger.GetLogger("fileprovider." + providerId)
	msgApi := NewMessageApi()
	tracer := p.Tracing.TracerProvider.Tracer("fileprovider." + providerId)

	if p.Js != nil {
		cfg := jetstream.StreamConfig{
			Name:     events.FileInfoStream,
			Subjects: []string{events.FileProviderFileInfoTopic},
		}

		_, err := p.Js.CreateOrUpdateStream(context.Background(), cfg)
		if err != nil {
			return nil, fmt.Errorf("Error while creating file info stream: %w", err)
		}
	}

	return &FileProviderServer{
		providerId: providerId,
		readOnly:   readOnly,
		log:        log,
		tracer:     tracer,
		nc:         p.Nc,
		msgApi:     msgApi,
		fs:         fileSystem,
	}, nil
}

func (s *FileProviderServer) Start() (err error) {
	providerTopic := FileProviderTopicPrefix + s.providerId
	s.requestChan = make(chan *nats.Msg, nats.DefaultSubPendingMsgsLimit)
	s.requestSub, err = s.nc.ChanQueueSubscribe(providerTopic, providerTopic, s.requestChan)
	s.ctx, s.cancel = context.WithCancel(context.Background())
	s.wg.Add(1)
	go s.messageLoop()
	return
}

func (s *FileProviderServer) Stop(force bool) (err error) {
	cancel := func() {
		if s.ctx != nil {
			s.cancel()
			s.cancel = nil
			s.ctx = nil
		}
	}

	// if force is true then cancel the context to force-close any open files
	if force {
		cancel()
	} else {
		defer cancel()
	}

	if s.requestSub != nil {
		err = s.requestSub.Unsubscribe()
		s.requestSub = nil
	}
	if s.requestChan != nil {
		close(s.requestChan)
		s.requestChan = nil
	}

	s.wg.Wait()

	return
}

func (s *FileProviderServer) messageLoop() {
	defer s.wg.Done()

	for {
		msg, ok := <-s.requestChan
		if !ok {
			return
		}
		s.wg.Add(1)
		go s.handleMessage(msg)
	}
}

func (s *FileProviderServer) handleMessage(msg *nats.Msg) {
	defer s.wg.Done()

	ctx := messaging.ExtractTraceContext(s.ctx, msg)
	request := FileProviderRequest{}
	s.msgApi.Unmarshal(FileProviderRequestSchema, msg.Data, &request)

	response := s.handleRequest(ctx, &request)
	data, _ := s.msgApi.Marshal(FileProviderResponseSchema, response)
	msg.Respond(data)
}

func (s *FileProviderServer) handleRequest(ctx context.Context, request *FileProviderRequest) *FileProviderResponse {
	switch req := request.Request.(type) {
	case MkdirRequest:
		return s.handleMkdir(ctx, request.Uid, &req)
	case OpenFileRequest:
		return s.handleOpenFile(ctx, request.Uid, &req)
	case RemoveAllRequest:
		return s.handleRemoveALl(ctx, request.Uid, &req)
	case RenameRequest:
		return s.handleRename(ctx, request.Uid, &req)
	case StatRequest:
		return s.handleStat(ctx, request.Uid, &req)
	default:
		return &FileProviderResponse{}
	}
}

func (s *FileProviderServer) handleMkdir(ctx context.Context, uid string, req *MkdirRequest) *FileProviderResponse {
	var span trace.Span
	ctx, span = s.tracer.Start(ctx, "mkdir")
	defer span.End()

	if s.readOnly {
		return &FileProviderResponse{
			Uid: uid,
			Response: MkdirResponse{
				Error: IoError{"read only", "ErrPermission"},
			},
		}
	}

	err := s.fs.Mkdir(ctx, req.Name, req.Perm)
	if err == nil {
		s.log.Debug("mkdir", "uid", uid, "req", req)
	} else {
		s.log.Debug("mkdir failed", "uid", uid, "req", req, "error", err)
	}

	return &FileProviderResponse{
		Uid: uid,
		Response: MkdirResponse{
			Error: toIoError(err),
		},
	}
}

func (s *FileProviderServer) handleOpenFile(ctx context.Context, uid string, req *OpenFileRequest) *FileProviderResponse {
	var span trace.Span
	_, span = s.tracer.Start(ctx, "open")
	defer span.End()

	flag := req.Flag
	if s.readOnly {
		flag = os.O_RDONLY
	}
	file, err := s.fs.OpenFile(ctx, req.Name, flag, req.Perm)
	if err == nil {
		s.log.Debug("openFile", "uid", uid, "req", req)
	} else {
		s.log.Debug("openFile failed", "uid", uid, "req", req, "error", err)
	}

	response := OpenFileResponse{}
	if err == nil {
		fileId := uuid.New()
		err = newServerFile(ctx, uid, fileId, req.Name, file, s)
		if err == nil {
			response.FileId = fileId.String()
		} else {
			response.Error = toIoError(err)
		}
	} else {
		response.Error = toIoError(err)
	}

	return &FileProviderResponse{
		Uid:      uid,
		Response: response,
	}
}

func (s *FileProviderServer) handleRemoveALl(ctx context.Context, uid string, req *RemoveAllRequest) *FileProviderResponse {
	var span trace.Span
	ctx, span = s.tracer.Start(ctx, "removeAll")
	defer span.End()

	if s.readOnly {
		return &FileProviderResponse{
			Uid: uid,
			Response: RemoveAllResponse{
				Error: IoError{"read only", "ErrPermission"},
			},
		}
	}

	err := s.fs.RemoveAll(ctx, req.Name)
	if err == nil {
		s.log.Debug("removeAll", "uid", uid, "req", req)
	} else {
		s.log.Debug("removeAll failed", "uid", uid, "req", req, "error", err)
	}

	return &FileProviderResponse{
		Uid: uid,
		Response: RemoveAllResponse{
			Error: toIoError(err),
		},
	}
}

func (s *FileProviderServer) handleRename(ctx context.Context, uid string, req *RenameRequest) *FileProviderResponse {
	var span trace.Span
	ctx, span = s.tracer.Start(ctx, "rename")
	defer span.End()

	if s.readOnly {
		return &FileProviderResponse{
			Uid: uid,
			Response: RenameResponse{
				Error: IoError{"read only", "ErrPermission"},
			},
		}
	}

	err := s.fs.Rename(ctx, req.OldName, req.NewName)
	if err == nil {
		s.log.Debug("rename", "uid", uid, "req", req)
	} else {
		s.log.Debug("rename failed", "uid", uid, "req", req, "error", err)
	}

	return &FileProviderResponse{
		Uid: uid,
		Response: RenameResponse{
			Error: toIoError(err),
		},
	}
}

func (s *FileProviderServer) handleStat(ctx context.Context, uid string, req *StatRequest) *FileProviderResponse {
	var span trace.Span
	ctx, span = s.tracer.Start(ctx, "stat")
	defer span.End()

	fileInfo, err := s.fs.Stat(ctx, req.Name)
	if err == nil {
		s.log.Debug("fileInfo", "uid", uid, "req", req)
	} else {
		s.log.Debug("fileInfo failed", "uid", uid, "req", req, "error", err)
	}

	response := FileInfoResponse{}
	if err == nil {
		response.Name = fileInfo.Name()
		response.IsDir = fileInfo.IsDir()
		response.Size = fileInfo.Size()
		response.Mode = fileInfo.Mode()
		response.ModTime = fileInfo.ModTime().Unix()

		s.publishFileInfoEvent(ctx, req.Name, fileInfo, nil)
	} else {
		response.Error = toIoError(err)
	}

	return &FileProviderResponse{
		Uid:      uid,
		Response: response,
	}
}

func (s *FileProviderServer) publishFileInfoEvent(ctx context.Context, path string, fileInfo os.FileInfo, readdir *events.ReadDir) error {
	fileInfoEvent := events.FileInfoEvent{
		Event: events.Event{
			ID:      uuid.NewString(),
			Version: 1,
		},
		Readdir:    readdir,
		ProviderID: s.providerId,
		Path:       ensureAbsolutePath(path),
		IsDir:      fileInfo.IsDir(),
		Size:       fileInfo.Size(),
		Mode:       int64(fileInfo.Mode()),
		ModTime:    fileInfo.ModTime().Unix(),
	}
	fileInfoEventData, _ := fileInfoEvent.Marshal()
	return s.nc.Publish(fmt.Sprintf(events.FileProviderFileInfoTopicPattern, s.providerId), fileInfoEventData)
}

func ensureAbsolutePath(p string) string {
	if !strings.HasPrefix(p, "/") {
		return "/" + p
	}
	return p
}
