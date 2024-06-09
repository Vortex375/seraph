package fileprovider

import (
	"os"

	"github.com/hamba/avro/v2"
)

const FileProviderTopicPrefix = "seraph.fileprovider."
const FileProviderFileTopicPrefix = "seraph.fileprovider_file."
const FileProviderReaddirTopicPrefix = "seraph.fileprovider_readdir."

type MkdirRequest struct {
	Name string      `avro:"name"`
	Perm os.FileMode `avro:"perm"`
}

var MkdirRequestSchema avro.Schema

type MkdirResponse struct {
	Error string `avro:"error"`
}

var MkdirResponseSchema avro.Schema

type OpenFileRequest struct {
	Name string      `avro:"name"`
	Flag int         `avro:"flag"`
	Perm os.FileMode `avro:"perm"`
}

var OpenFileRequestSchema avro.Schema

type OpenFileResponse struct {
	FileId string `avro:"fileId"`
	Error  string `avro:"error"`
}

var OpenFileResponseSchema avro.Schema

type RemoveAllRequest struct {
	Name string `avro:"name"`
}

var RemoveAllRequestSchema avro.Schema

type RemoveAllResponse struct {
	Error string `avro:"error"`
}

var RemoveAllResponseSchema avro.Schema

type RenameRequest struct {
	OldName string `avro:"oldName"`
	NewName string `avro:"newName"`
}

var RenameRequestSchema avro.Schema

type RenameResponse struct {
	Error string `avro:"error"`
}

var RenameResponseSchema avro.Schema

type StatRequest struct {
	Name string `avro:"name"`
}

var StatRequestSchema avro.Schema

type FileInfoResponse struct {
	Name    string      `avro:"name"`
	Size    int64       `avro:"size"`
	Mode    os.FileMode `avro:"mode"`
	ModTime int64       `avro:"modTime"`
	IsDir   bool        `avro:"isDir"`
	Error   string      `avro:"error"`
	Last    bool        `avro:"last"`
}

var FileInfoResponseSchema avro.Schema

type FileCloseRequest struct {
}

var FileCloseRequestSchema avro.Schema

type FileReadRequest struct {
	Len uint32 `avro:"len"`
}

var FileReadRequestSchema avro.Schema

type FileReadResponse struct {
	Error   string `avro:"error"`
	Payload []byte `avro:"payload"`
}

var FileReadResponseSchema avro.Schema

type FileWriteRequest struct {
	Payload []byte `avro:"payload"`
}

var FileWriteRequestSchema avro.Schema

type FileWriteResponse struct {
	Error string `avro:"error"`
	Len   int    `avro:"len"`
}

var FileWriteResponseSchema avro.Schema

type FileSeekRequest struct {
	Offset int64 `avro:"offset"`
	Whence int   `avro:"whence"`
}

var FileSeekRequestSchema avro.Schema

type FileSeekResponse struct {
	Offset int64  `avro:"offset"`
	Error  string `avro:"error"`
}

var FileSeekResponseSchema avro.Schema

type FileCloseResponse struct {
	Error string `avro:"error"`
}

var FileCloseResponseSchema avro.Schema

type ReaddirRequest struct {
	Count int `avro:"count"`
}

var ReaddirRequestSchema avro.Schema

type ReaddirResponse struct {
	Count int    `avro:"count"`
	Error string `avro:"error"`
}

var ReaddirResponseSchema avro.Schema

type FileProviderRequest struct {
	Uid     string `avro:"uid"`
	Request any    `avro:"request"`
}

var FileProviderRequestSchema avro.Schema

type FileProviderResponse struct {
	Uid      string `avro:"uid"`
	Response any    `avro:"response"`
}

var FileProviderResponseSchema avro.Schema

type FileProviderFileRequest struct {
	Uid     string `avro:"uid"`
	FileId  string `avro:"fileId"`
	Request any    `avro:"request"`
}

var FileProviderFileRequestSchema avro.Schema

type FileProviderFileResponse struct {
	Uid      string `avro:"uid"`
	Response any    `avro:"response"`
}

var FileProviderFileResponseSchema avro.Schema

func init() {
	MkdirRequestSchema = avro.MustParse(`{
		"type": "record",
		"name": "MkdirRequest",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "name", "type": "string"},
			{"name": "perm", "type": "long"}
		]
	}`)

	MkdirResponseSchema = avro.MustParse(`{
		"type": "record",
		"name": "MkdirResponse",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "error", "type": "string"}
		]
	}`)

	OpenFileRequestSchema = avro.MustParse(`{
		"type": "record",
		"name": "OpenFileRequest",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "name", "type": "string"},
			{"name": "flag", "type": "int"},
			{"name": "perm", "type": "long"}
		]
	}`)

	OpenFileResponseSchema = avro.MustParse(`{
		"type": "record",
		"name": "OpenFileResponse",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "fileId", "type": "string"},
			{"name": "error", "type": "string"}
		]
	}`)

	RemoveAllRequestSchema = avro.MustParse(`{
		"type": "record",
		"name": "RemoveAllRequest",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "name", "type": "string"}
		]
	}`)

	RemoveAllResponseSchema = avro.MustParse(`{
		"type": "record",
		"name": "RemoveAllResponse",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "error", "type": "string"}
		]
	}`)

	RenameRequestSchema = avro.MustParse(`{
		"type": "record",
		"name": "RenameRequest",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "oldName", "type": "string"},
			{"name": "newName", "type": "string"}
		]
	}`)

	RenameResponseSchema = avro.MustParse(`{
		"type": "record",
		"name": "RenameResponse",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "error", "type": "string"}
		]
	}`)

	StatRequestSchema = avro.MustParse(`{
		"type": "record",
		"name": "StatRequest",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "name", "type": "string"}
		]
	}`)

	FileInfoResponseSchema = avro.MustParse(`{
		"type": "record",
		"name": "FileInfoResponse",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "name", "type": "string"},
			{"name": "size", "type": "long"},
			{"name": "mode", "type": "long"},
			{"name": "modTime", "type": "long"},
			{"name": "isDir", "type": "boolean"},
			{"name": "error", "type": "string"},
			{"name": "last", "type": "boolean"}
		]
	}`)

	FileCloseRequestSchema = avro.MustParse(`{
		"type": "record",
		"name": "FileCloseRequest",
		"namespace": "seraph.fileprovider",
		"fields": [
		]
	}`)

	FileCloseResponseSchema = avro.MustParse(`{
		"type": "record",
		"name": "FileCloseResponse",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "error", "type": "string"}
		]
	}`)

	FileReadRequestSchema = avro.MustParse(`{
		"type": "record",
		"name": "FileReadRequest",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "len", "type": "long"}
		]
	}`)

	FileReadResponseSchema = avro.MustParse(`{
		"type": "record",
		"name": "FileReadResponse",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "error", "type": "string"},
			{"name": "payload", "type": "bytes"}
		]
	}`)

	FileWriteRequestSchema = avro.MustParse(`{
		"type": "record",
		"name": "FileWriteRequest",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "payload", "type": "bytes"}
		]
	}`)

	FileWriteResponseSchema = avro.MustParse(`{
		"type": "record",
		"name": "FileWriteResponse",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "error", "type": "string"},
			{"name": "len", "type": "int"}
		]
	}`)

	FileSeekRequestSchema = avro.MustParse(`{
		"type": "record",
		"name": "FileSeekRequest",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "offset", "type": "long"},
			{"name": "whence", "type": "int"}
		]
	}`)

	FileSeekResponseSchema = avro.MustParse(`{
		"type": "record",
		"name": "FileSeekResponse",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "offset", "type": "long"},
			{"name": "error", "type": "string"}
		]
	}`)

	ReaddirRequestSchema = avro.MustParse(`{
		"type": "record",
		"name": "ReaddirRequest",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "count", "type": "int"}
		]
	}`)

	ReaddirResponseSchema = avro.MustParse(`{
		"type": "record",
		"name": "ReaddirResponse",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "count", "type": "int"},
			{"name": "error", "type": "string"}
		]
	}`)

	FileProviderRequestSchema = avro.MustParse(`{
		"type": "record",
		"name": "FileProviderRequest",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "uid", "type": "string"},
			{"name": "request", "type": [
				"MkdirRequest",
				"OpenFileRequest",
				"RemoveAllRequest",
				"RenameRequest",
				"StatRequest"
			]}
		]
	}`)

	FileProviderResponseSchema = avro.MustParse(`{
		"type": "record",
		"name": "FileProviderResponse",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "uid", "type": "string"},
			{"name": "response", "type": [
				"MkdirResponse",
				"OpenFileResponse",
				"RemoveAllResponse",
				"RenameResponse",
				"FileInfoResponse"
			]}
		]
	}`)

	FileProviderFileRequestSchema = avro.MustParse(`{
		"type": "record",
		"name": "FileProviderFileRequest",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "uid", "type": "string"},
			{"name": "fileId", "type": "string"},
			{"name": "request", "type": [
				"FileCloseRequest",
				"FileReadRequest",
				"FileWriteRequest",
				"FileSeekRequest",
				"ReaddirRequest"
			]}
		]
	}`)

	FileProviderFileResponseSchema = avro.MustParse(`{
		"type": "record",
		"name": "FileProviderFileResponse",
		"namespace": "seraph.fileprovider",
		"fields": [
			{"name": "uid", "type": "string"},
			{"name": "response", "type": [
				"FileCloseResponse",
				"FileReadResponse",
				"FileSeekResponse",
				"FileWriteResponse",
				"ReaddirResponse"
			]}
		]
	}`)
}

func NewMessageApi() avro.API {
	api := avro.Config{
		UnionResolutionError:       true,
		PartialUnionTypeResolution: false,
	}.Freeze()

	//Request types
	api.Register("seraph.fileprovider.MkdirRequest", MkdirRequest{})
	api.Register("seraph.fileprovider.OpenFileRequest", OpenFileRequest{})
	api.Register("seraph.fileprovider.RemoveAllRequest", RemoveAllRequest{})
	api.Register("seraph.fileprovider.RenameRequest", RenameRequest{})
	api.Register("seraph.fileprovider.StatRequest", StatRequest{})

	//Response types
	api.Register("seraph.fileprovider.MkdirResponse", MkdirResponse{})
	api.Register("seraph.fileprovider.OpenFileResponse", OpenFileResponse{})
	api.Register("seraph.fileprovider.RemoveAllResponse", RemoveAllResponse{})
	api.Register("seraph.fileprovider.RenameResponse", RenameResponse{})
	api.Register("seraph.fileprovider.FileInfoResponse", FileInfoResponse{})

	//File Request types
	api.Register("seraph.fileprovider.FileCloseRequest", FileCloseRequest{})
	api.Register("seraph.fileprovider.FileReadRequest", FileReadRequest{})
	api.Register("seraph.fileprovider.FileWriteRequest", FileWriteRequest{})
	api.Register("seraph.fileprovider.FileSeekRequest", FileSeekRequest{})
	api.Register("seraph.fileprovider.ReaddirRequest", ReaddirRequest{})

	//File Response types
	api.Register("seraph.fileprovider.FileCloseResponse", FileCloseResponse{})
	api.Register("seraph.fileprovider.FileReadResponse", FileReadResponse{})
	api.Register("seraph.fileprovider.FileSeekResponse", FileSeekResponse{})
	api.Register("seraph.fileprovider.FileWriteResponse", FileWriteResponse{})
	api.Register("seraph.fileprovider.ReaddirResponse", ReaddirResponse{})

	//Message types
	api.Register("seraph.fileprovider.FileProviderRequest", FileProviderRequest{})
	api.Register("seraph.fileprovider.FileProviderResponse", FileProviderResponse{})
	api.Register("seraph.fileprovider.FileProviderFileRequest", FileProviderFileRequest{})
	api.Register("seraph.fileprovider.FileProviderFileResponse", FileProviderFileResponse{})

	return api
}
