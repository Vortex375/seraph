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
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/logging"
)

type FileProviderServer struct {
	ProviderId string
}

type fileHolder struct {
	fileId       uuid.UUID
	file         webdav.File
	lastAccess   time.Time
	subscription *nats.Subscription
}

func NewFileProviderServer(providerId string, nc *nats.Conn, fileSystem webdav.FileSystem, readOnly bool, logger *logging.Logger) *FileProviderServer {
	log := logger.GetLogger("fileprovider." + providerId)
	provider := FileProviderServer{
		ProviderId: providerId,
	}
	msgApi := NewMessageApi()

	//TODO: close files after timeout
	openFiles := make(map[uuid.UUID]fileHolder)

	providerTopic := FileProviderTopicPrefix + providerId
	nc.QueueSubscribe(providerTopic, providerTopic, func(msg *nats.Msg) {
		context := context.TODO()
		request := FileProviderRequest{}
		msgApi.Unmarshal(FileProviderRequestSchema, msg.Data, &request)
		switch req := request.Request.(type) {

		case MkdirRequest:
			if readOnly {
				responseData, _ := msgApi.Marshal(FileProviderResponseSchema, FileProviderResponse{
					Uid: request.Uid,
					Response: MkdirResponse{
						Error: "read only",
					},
				})
				msg.Respond(responseData)
				break
			}
			err := fileSystem.Mkdir(context, req.Name, req.Perm)
			var errStr string
			if err == nil {
				log.Debug("mkdir", "uid", request.Uid, "req", req)
			} else {
				log.Debug("mkdir failed", "uid", request.Uid, "req", req, "error", err)
				errStr = err.Error()
			}
			responseData, _ := msgApi.Marshal(FileProviderResponseSchema, FileProviderResponse{
				Uid: request.Uid,
				Response: MkdirResponse{
					Error: errStr,
				},
			})
			msg.Respond(responseData)

		case RemoveAllRequest:
			if readOnly {
				responseData, _ := msgApi.Marshal(FileProviderResponseSchema, FileProviderResponse{
					Uid: request.Uid,
					Response: RemoveAllResponse{
						Error: "read only",
					},
				})
				msg.Respond(responseData)
				break
			}
			err := fileSystem.RemoveAll(context, req.Name)
			var errStr string
			if err == nil {
				log.Debug("removeAll", "uid", request.Uid, "req", req)
			} else {
				log.Debug("removeAll failed", "uid", request.Uid, "req", req, "error", err)
				errStr = err.Error()
			}
			responseData, _ := msgApi.Marshal(FileProviderResponseSchema, FileProviderResponse{
				Uid: request.Uid,
				Response: RemoveAllResponse{
					Error: errStr,
				},
			})
			msg.Respond(responseData)

		case RenameRequest:
			if readOnly {
				responseData, _ := msgApi.Marshal(FileProviderResponseSchema, FileProviderResponse{
					Uid: request.Uid,
					Response: RenameResponse{
						Error: "read only",
					},
				})
				msg.Respond(responseData)
				break
			}
			err := fileSystem.Rename(context, req.OldName, req.NewName)
			var errStr string
			if err == nil {
				log.Debug("rename", "uid", request.Uid, "req", req)
			} else {
				log.Debug("rename failed", "uid", request.Uid, "req", req, "error", err)
				errStr = err.Error()
			}
			responseData, _ := msgApi.Marshal(FileProviderResponseSchema, FileProviderResponse{
				Uid: request.Uid,
				Response: RenameResponse{
					Error: errStr,
				},
			})
			msg.Respond(responseData)

		case StatRequest:
			fileInfo, err := fileSystem.Stat(context, req.Name)
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
					Readdir:    "",
					Last:       false,
					Path:       ensureAbsolutePath(req.Name),
					IsDir:      fileInfo.IsDir(),
					Size:       fileInfo.Size(),
					Mode:       int64(fileInfo.Mode()),
					ModTime:    fileInfo.ModTime().Unix(),
				}
				fileInfoEventData, _ := events.Api.Marshal(events.Schema, fileInfoEvent)
				nc.Publish(fmt.Sprintf(events.FileProviderFileInfoTopicPattern, providerId), fileInfoEventData)

			} else {
				response.Error = err.Error()
			}
			responseData, _ := msgApi.Marshal(FileProviderResponseSchema, FileProviderResponse{
				Uid:      request.Uid,
				Response: response,
			})
			msg.Respond(responseData)

		case OpenFileRequest:
			flag := req.Flag
			if readOnly {
				flag = os.O_RDONLY
			}
			file, err := fileSystem.OpenFile(context, req.Name, flag, req.Perm)
			if err == nil {
				log.Debug("openFile", "uid", request.Uid, "req", req)
			} else {
				log.Debug("openFile failed", "uid", request.Uid, "req", req, "error", err)
			}
			response := OpenFileResponse{}
			if err == nil {
				fileId := uuid.New()
				fileTopic := FileProviderFileTopicPrefix + fileId.String()
				subscription, _ := nc.Subscribe(fileTopic, func(fileMsg *nats.Msg) {
					fileRequest := FileProviderFileRequest{}
					err = msgApi.Unmarshal(FileProviderFileRequestSchema, fileMsg.Data, &fileRequest)
					if err != nil {
						log.Error("unable to parse file request", "err", err)
						return
					}

					switch fileReq := fileRequest.Request.(type) {

					case FileCloseRequest:
						err = file.Close()
						var errStr string
						if err == nil {
							log.Debug("fileClose", "uid", fileRequest.Uid, "fileId", fileRequest.FileId, "req", fileReq)
						} else {
							log.Error("fileClose failed", "uid", request.Uid, "fileId", fileRequest.FileId, "req", fileReq, "error", err)
							errStr = err.Error()
						}
						openFiles[fileId].subscription.Unsubscribe()
						delete(openFiles, fileId)
						fileResponseData, _ := msgApi.Marshal(FileProviderFileResponseSchema, FileProviderFileResponse{
							Uid: fileRequest.Uid,
							Response: FileCloseResponse{
								Error: errStr,
							},
						})
						fileMsg.Respond(fileResponseData)

					case FileReadRequest:
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
							fileResponse.Error = err.Error()
						}
						fileResponseData, _ := msgApi.Marshal(FileProviderFileResponseSchema, FileProviderFileResponse{
							Uid:      fileRequest.Uid,
							Response: fileResponse,
						})
						fileMsg.Respond(fileResponseData)

					case FileWriteRequest:
						if readOnly {
							fileResponseData, _ := msgApi.Marshal(FileProviderFileResponseSchema, FileProviderFileResponse{
								Uid: fileRequest.Uid,
								Response: FileWriteResponse{
									Error: "read only",
								},
							})
							fileMsg.Respond(fileResponseData)
							break
						}
						len, err := file.Write(fileReq.Payload)
						var errStr string
						if err == nil {
							log.Debug("fileWrite", "uid", fileRequest.Uid, "fileId", fileRequest.FileId)
						} else {
							log.Error("fileWrite failed", "uid", request.Uid, "fileId", fileRequest.FileId, "error", err)
							errStr = err.Error()
						}
						fileResponseData, _ := msgApi.Marshal(FileProviderFileResponseSchema, FileProviderFileResponse{
							Uid: fileRequest.Uid,
							Response: FileWriteResponse{
								Len:   len,
								Error: errStr,
							},
						})
						fileMsg.Respond(fileResponseData)

					case FileSeekRequest:
						offset, err := file.Seek(fileReq.Offset, fileReq.Whence)
						var errStr string
						if err == nil {
							log.Debug("fileSeek", "uid", fileRequest.Uid, "fileId", fileRequest.FileId, "req", fileReq)
						} else {
							log.Error("fileSeek failed", "uid", request.Uid, "fileId", fileRequest.FileId, "req", fileReq, "error", err)
							errStr = err.Error()
						}
						fileResponseData, _ := msgApi.Marshal(FileProviderFileResponseSchema, FileProviderFileResponse{
							Uid: fileRequest.Uid,
							Response: FileSeekResponse{
								Offset: offset,
								Error:  errStr,
							},
						})
						fileMsg.Respond(fileResponseData)

					case ReaddirRequest:
						fileInfos, err := file.Readdir(fileReq.Count)
						if err == nil {
							log.Debug("readdir", "uid", fileRequest.Uid, "fileId", fileRequest.FileId, "req", fileReq)
						} else {
							log.Error("readdir failed", "uid", request.Uid, "fileId", fileRequest.FileId, "req", fileReq, "error", err)
						}
						if err == nil {
							fileInfoEvent := events.FileInfoEvent{
								Event: events.Event{
									ID:      uuid.NewString(),
									Version: 1,
								},
								ProviderID: providerId,
								Readdir:    fileRequest.Uid,
								Last:       false,
								Path:       ensureAbsolutePath(req.Name),
								IsDir:      true,
							}
							fileInfoEventData, _ := events.Api.Marshal(events.Schema, fileInfoEvent)
							nc.Publish(fmt.Sprintf(events.FileProviderFileInfoTopicPattern, providerId), fileInfoEventData)

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
								e = nc.Publish(FileProviderReaddirTopicPrefix+fileRequest.Uid, fileInfoResponseData)
								if e != nil {
									err = e
									break
								}
								fileInfoEvent := events.FileInfoEvent{
									Event: events.Event{
										ID:      uuid.NewString(),
										Version: 1,
									},
									ProviderID: providerId,
									Readdir:    fileRequest.Uid,
									Last:       (fileReq.Count <= 0 || len(fileInfos) < fileReq.Count) && i == len(fileInfos)-1,
									Path:       ensureAbsolutePath(req.Name + "/" + fileInfo.Name()),
									IsDir:      fileInfo.IsDir(),
									Size:       fileInfo.Size(),
									Mode:       int64(fileInfo.Mode()),
									ModTime:    fileInfo.ModTime().Unix(),
								}
								fileInfoEventData, _ := events.Api.Marshal(events.Schema, fileInfoEvent)
								nc.Publish(fmt.Sprintf(events.FileProviderFileInfoTopicPattern, providerId), fileInfoEventData)
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
									Error: err.Error(),
								},
							})
						}
						nc.Flush()
						fileMsg.Respond(fileResponseData)

					default:
						log.Error("unknown file request", "req", fileRequest.Request)
					}
				})
				openFiles[fileId] = fileHolder{fileId, file, time.Now(), subscription}
				response.FileId = fileId.String()
			} else {
				response.Error = err.Error()
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
