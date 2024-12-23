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
	"os"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/fx"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/tracing"
)

type FileProviderServer struct {
	ProviderId string
}

type ServerParams struct {
	fx.In

	Nc      *nats.Conn
	Js      jetstream.JetStream
	Logger  *logging.Logger
	Tracing *tracing.Tracing
}

type fileHolder struct {
	fileId       uuid.UUID
	file         webdav.File
	lastAccess   time.Time
	subscription *nats.Subscription
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

func NewFileProviderServer(p ServerParams, providerId string, fileSystem webdav.FileSystem, readOnly bool) *FileProviderServer {
	log := p.Logger.GetLogger("fileprovider." + providerId)
	provider := FileProviderServer{
		ProviderId: providerId,
	}
	msgApi := NewMessageApi()
	tracer := p.Tracing.TracerProvider.Tracer("fileprovider." + providerId)

	if p.Js != nil {
		cfg := jetstream.StreamConfig{
			Name:     events.FileInfoStream,
			Subjects: []string{events.FileProviderFileInfoTopic},
		}

		_, err := p.Js.CreateOrUpdateStream(context.Background(), cfg)
		if err != nil {
			log.Error("Error while creating file info stream", "error", err)
		}
	}

	//TODO: close files after timeout
	openFiles := make(map[uuid.UUID]fileHolder)

	providerTopic := FileProviderTopicPrefix + providerId
	p.Nc.QueueSubscribe(providerTopic, providerTopic, func(msg *nats.Msg) {
		ctx := context.Background()
		propagator := propagation.TraceContext{}
		ctx = propagator.Extract(ctx, propagation.HeaderCarrier(msg.Header))

		request := FileProviderRequest{}
		msgApi.Unmarshal(FileProviderRequestSchema, msg.Data, &request)
		switch req := request.Request.(type) {

		case MkdirRequest:
			var span trace.Span
			ctx, span = tracer.Start(ctx, "mkdir")
			defer span.End()
			if readOnly {
				responseData, _ := msgApi.Marshal(FileProviderResponseSchema, FileProviderResponse{
					Uid: request.Uid,
					Response: MkdirResponse{
						Error: IoError{"read only", "ErrPermission"},
					},
				})
				msg.Respond(responseData)
				break
			}
			err := fileSystem.Mkdir(ctx, req.Name, req.Perm)
			if err == nil {
				log.Debug("mkdir", "uid", request.Uid, "req", req)
			} else {
				log.Debug("mkdir failed", "uid", request.Uid, "req", req, "error", err)
			}
			responseData, _ := msgApi.Marshal(FileProviderResponseSchema, FileProviderResponse{
				Uid: request.Uid,
				Response: MkdirResponse{
					Error: toIoError(err),
				},
			})
			msg.Respond(responseData)

		case RemoveAllRequest:
			var span trace.Span
			ctx, span = tracer.Start(ctx, "removeAll")
			defer span.End()
			if readOnly {
				responseData, _ := msgApi.Marshal(FileProviderResponseSchema, FileProviderResponse{
					Uid: request.Uid,
					Response: RemoveAllResponse{
						Error: IoError{"read only", "ErrPermission"},
					},
				})
				msg.Respond(responseData)
				break
			}
			err := fileSystem.RemoveAll(ctx, req.Name)
			if err == nil {
				log.Debug("removeAll", "uid", request.Uid, "req", req)
			} else {
				log.Debug("removeAll failed", "uid", request.Uid, "req", req, "error", err)
			}
			responseData, _ := msgApi.Marshal(FileProviderResponseSchema, FileProviderResponse{
				Uid: request.Uid,
				Response: RemoveAllResponse{
					Error: toIoError(err),
				},
			})
			msg.Respond(responseData)

		case RenameRequest:
			var span trace.Span
			ctx, span = tracer.Start(ctx, "rename")
			defer span.End()

			if readOnly {
				responseData, _ := msgApi.Marshal(FileProviderResponseSchema, FileProviderResponse{
					Uid: request.Uid,
					Response: RenameResponse{
						Error: IoError{"read only", "ErrPermission"},
					},
				})
				msg.Respond(responseData)
				break
			}
			err := fileSystem.Rename(ctx, req.OldName, req.NewName)
			if err == nil {
				log.Debug("rename", "uid", request.Uid, "req", req)
			} else {
				log.Debug("rename failed", "uid", request.Uid, "req", req, "error", err)
			}
			responseData, _ := msgApi.Marshal(FileProviderResponseSchema, FileProviderResponse{
				Uid: request.Uid,
				Response: RenameResponse{
					Error: toIoError(err),
				},
			})
			msg.Respond(responseData)

		case StatRequest:
			var span trace.Span
			ctx, span = tracer.Start(ctx, "stat")
			defer span.End()

			fileInfo, err := fileSystem.Stat(ctx, req.Name)
			if err == nil {
				log.Debug("fileInfo", "uid", request.Uid, "req", req)
			} else {
				log.Debug("fileInfo failed", "uid", request.Uid, "req", req, "error", err)
			}
			response := FileInfoResponse{}
			if err == nil {
				response.Name = fileInfo.Name()
				response.IsDir = fileInfo.IsDir()
				response.Size = fileInfo.Size()
				response.Mode = fileInfo.Mode()
				response.ModTime = fileInfo.ModTime().Unix()

				fileInfoEvent := events.FileInfoEvent{
					Event: events.Event{
						ID:      uuid.NewString(),
						Version: 1,
					},
					ProviderID: providerId,
					Path:       ensureAbsolutePath(req.Name),
					IsDir:      fileInfo.IsDir(),
					Size:       fileInfo.Size(),
					Mode:       int64(fileInfo.Mode()),
					ModTime:    fileInfo.ModTime().Unix(),
				}
				fileInfoEventData, _ := fileInfoEvent.Marshal()
				p.Nc.Publish(fmt.Sprintf(events.FileProviderFileInfoTopicPattern, providerId), fileInfoEventData)

			} else {
				response.Error = toIoError(err)
			}
			responseData, _ := msgApi.Marshal(FileProviderResponseSchema, FileProviderResponse{
				Uid:      request.Uid,
				Response: response,
			})
			msg.Respond(responseData)

		case OpenFileRequest:
			var span trace.Span
			ctx, span = tracer.Start(ctx, "open")
			defer span.End()

			flag := req.Flag
			if readOnly {
				flag = os.O_RDONLY
			}
			file, err := fileSystem.OpenFile(ctx, req.Name, flag, req.Perm)
			if err == nil {
				log.Debug("openFile", "uid", request.Uid, "req", req)
			} else {
				log.Debug("openFile failed", "uid", request.Uid, "req", req, "error", err)
			}
			response := OpenFileResponse{}
			if err == nil {
				fileId := uuid.New()
				fileTopic := FileProviderFileTopicPrefix + fileId.String()
				subscription, _ := p.Nc.Subscribe(fileTopic, func(fileMsg *nats.Msg) {
					ctx := context.Background()
					propagator := propagation.TraceContext{}
					ctx = propagator.Extract(ctx, propagation.HeaderCarrier(fileMsg.Header))

					fileRequest := FileProviderFileRequest{}
					err = msgApi.Unmarshal(FileProviderFileRequestSchema, fileMsg.Data, &fileRequest)
					if err != nil {
						log.Error("unable to parse file request", "err", err)
						return
					}

					switch fileReq := fileRequest.Request.(type) {

					case FileCloseRequest:
						var span trace.Span
						ctx, span = tracer.Start(ctx, "close")
						defer span.End()

						err = file.Close()
						if err == nil {
							log.Debug("fileClose", "uid", fileRequest.Uid, "fileId", fileRequest.FileId, "req", fileReq)
						} else {
							log.Error("fileClose failed", "uid", request.Uid, "fileId", fileRequest.FileId, "req", fileReq, "error", err)
						}
						openFiles[fileId].subscription.Unsubscribe()
						delete(openFiles, fileId)
						fileResponseData, _ := msgApi.Marshal(FileProviderFileResponseSchema, FileProviderFileResponse{
							Uid: fileRequest.Uid,
							Response: FileCloseResponse{
								Error: toIoError(err),
							},
						})
						fileMsg.Respond(fileResponseData)

					case FileReadRequest:
						var span trace.Span
						ctx, span = tracer.Start(ctx, "read")
						defer span.End()

						//TODO: validate Len
						buf := make([]byte, fileReq.Len)
						len, err := file.Read(buf)
						if err == nil {
							log.Debug("fileRead", "uid", fileRequest.Uid, "fileId", fileRequest.FileId, "req", fileReq)
						} else {
							log.Error("fileRead failed", "uid", request.Uid, "fileId", fileRequest.FileId, "req", fileReq, "error", err)
						}
						fileResponse := FileReadResponse{}
						if err == nil {
							fileResponse.Payload = buf[0:len]
						} else {
							fileResponse.Error = toIoError(err)
						}
						fileResponseData, _ := msgApi.Marshal(FileProviderFileResponseSchema, FileProviderFileResponse{
							Uid:      fileRequest.Uid,
							Response: fileResponse,
						})
						fileMsg.Respond(fileResponseData)

					case FileWriteRequest:
						var span trace.Span
						ctx, span = tracer.Start(ctx, "write")
						defer span.End()

						if readOnly {
							fileResponseData, _ := msgApi.Marshal(FileProviderFileResponseSchema, FileProviderFileResponse{
								Uid: fileRequest.Uid,
								Response: FileWriteResponse{
									Error: IoError{"read only", "ErrPermission"},
								},
							})
							fileMsg.Respond(fileResponseData)
							break
						}
						len, err := file.Write(fileReq.Payload)
						if err == nil {
							log.Debug("fileWrite", "uid", fileRequest.Uid, "fileId", fileRequest.FileId)
						} else {
							log.Error("fileWrite failed", "uid", request.Uid, "fileId", fileRequest.FileId, "error", err)
						}
						fileResponseData, _ := msgApi.Marshal(FileProviderFileResponseSchema, FileProviderFileResponse{
							Uid: fileRequest.Uid,
							Response: FileWriteResponse{
								Len:   len,
								Error: toIoError(err),
							},
						})
						fileMsg.Respond(fileResponseData)

					case FileSeekRequest:
						var span trace.Span
						ctx, span = tracer.Start(ctx, "seek")
						defer span.End()

						offset, err := file.Seek(fileReq.Offset, fileReq.Whence)
						if err == nil {
							log.Debug("fileSeek", "uid", fileRequest.Uid, "fileId", fileRequest.FileId, "req", fileReq)
						} else {
							log.Error("fileSeek failed", "uid", request.Uid, "fileId", fileRequest.FileId, "req", fileReq, "error", err)
						}
						fileResponseData, _ := msgApi.Marshal(FileProviderFileResponseSchema, FileProviderFileResponse{
							Uid: fileRequest.Uid,
							Response: FileSeekResponse{
								Offset: offset,
								Error:  toIoError(err),
							},
						})
						fileMsg.Respond(fileResponseData)

					case ReaddirRequest:
						var span trace.Span
						ctx, span = tracer.Start(ctx, "readdir")
						defer span.End()

						fileInfos, err := file.Readdir(fileReq.Count)
						if err == nil {
							log.Debug("readdir", "uid", fileRequest.Uid, "fileId", fileRequest.FileId, "req", fileReq)
						} else {
							log.Error("readdir failed", "uid", request.Uid, "fileId", fileRequest.FileId, "req", fileReq, "error", err)
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
								fileInfoResponseData, e := msgApi.Marshal(FileInfoResponseSchema, &fileInfoResponse)
								if e != nil {
									err = e
									break
								}
								e = p.Nc.Publish(FileProviderReaddirTopicPrefix+fileRequest.Uid, fileInfoResponseData)
								if e != nil {
									err = e
									break
								}

								var readdir *events.ReadDir
								if fileReq.Count <= 0 || len(fileInfos) < fileReq.Count {
									// if it lists the entire directory
									readdir = &events.ReadDir{
										Readdir: fileRequest.Uid,
										Index:   int64(i),
										Total:   int64(len(fileInfos)),
									}
								} else {
									// partial readdir is not published as readdir
									readdir = nil
								}

								fileInfoEvent := events.FileInfoEvent{
									Event: events.Event{
										ID:      uuid.NewString(),
										Version: 1,
									},
									ProviderID: providerId,
									Readdir:    readdir,
									Path:       ensureAbsolutePath(req.Name + "/" + fileInfo.Name()),
									IsDir:      fileInfo.IsDir(),
									Size:       fileInfo.Size(),
									Mode:       int64(fileInfo.Mode()),
									ModTime:    fileInfo.ModTime().Unix(),
								}
								fileInfoEventData, _ := fileInfoEvent.Marshal()
								p.Nc.Publish(fmt.Sprintf(events.FileProviderFileInfoTopicPattern, providerId), fileInfoEventData)
							}
						}
						var fileResponseData []byte
						if err == nil {
							fileResponseData, _ = msgApi.Marshal(FileProviderFileResponseSchema, FileProviderFileResponse{
								Uid: fileRequest.Uid,
								Response: ReaddirResponse{
									Count: len(fileInfos),
								},
							})
						} else {
							fileResponseData, _ = msgApi.Marshal(FileProviderFileResponseSchema, FileProviderFileResponse{
								Uid: fileRequest.Uid,
								Response: ReaddirResponse{
									Error: toIoError(err),
								},
							})
						}
						p.Nc.Flush()
						fileMsg.Respond(fileResponseData)

					default:
						log.Error("unknown file request", "req", fileRequest.Request)
					}
				})
				openFiles[fileId] = fileHolder{fileId, file, time.Now(), subscription}
				response.FileId = fileId.String()
			} else {
				response.Error = toIoError(err)
			}
			responseData, _ := msgApi.Marshal(FileProviderResponseSchema, FileProviderResponse{
				Uid:      request.Uid,
				Response: response,
			})
			msg.Respond(responseData)

		default:
			log.Error("unknown request", "req", request.Request)
		}
	})
	log.Info("fileprovider active", "topic", providerTopic)

	return &provider
}

func ensureAbsolutePath(p string) string {
	if !strings.HasPrefix(p, "/") {
		return "/" + p
	}
	return p
}
