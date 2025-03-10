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
	"io"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/hamba/avro/v2"
	"github.com/stretchr/testify/assert"
)

func TestMessages(t *testing.T) {
	api := NewMessageApi()

	//File Provider Requests

	t.Run("MkdirRequest", func(t *testing.T) {
		doTestFileProviderRequest(t, api, FileProviderRequest{
			Uid: uuid.NewString(),
			Request: MkdirRequest{
				Name: "testdir",
				Perm: 0644,
			},
		})
	})
	t.Run("OpenFileRequest", func(t *testing.T) {
		doTestFileProviderRequest(t, api, FileProviderRequest{
			Uid: uuid.NewString(),
			Request: OpenFileRequest{
				Name: "testfile",
				Flag: os.O_RDONLY,
				Perm: 0644,
			},
		})
	})
	t.Run("RemoveAllRequest", func(t *testing.T) {
		doTestFileProviderRequest(t, api, FileProviderRequest{
			Uid: uuid.NewString(),
			Request: RemoveAllRequest{
				Name: "testdir",
			},
		})
	})
	t.Run("RenameRequest", func(t *testing.T) {
		doTestFileProviderRequest(t, api, FileProviderRequest{
			Uid: uuid.NewString(),
			Request: RenameRequest{
				OldName: "oldName",
				NewName: "newName",
			},
		})
	})
	t.Run("StatRequest", func(t *testing.T) {
		doTestFileProviderRequest(t, api, FileProviderRequest{
			Uid: uuid.NewString(),
			Request: StatRequest{
				Name: "testdir",
			},
		})
	})

	//File Provider Responses

	t.Run("MkdirResponse", func(t *testing.T) {
		doTestFileProviderResponse(t, api, FileProviderResponse{
			Uid: uuid.NewString(),
			Response: MkdirResponse{
				Error: IoError{Error: "err"},
			},
		})
	})
	t.Run("OpenFileResponse", func(t *testing.T) {
		doTestFileProviderResponse(t, api, FileProviderResponse{
			Uid: uuid.NewString(),
			Response: OpenFileResponse{
				Error:  IoError{Error: "err"},
				FileId: "some-file",
			},
		})
	})
	t.Run("RemoveAllResponse", func(t *testing.T) {
		doTestFileProviderResponse(t, api, FileProviderResponse{
			Uid: uuid.NewString(),
			Response: RemoveAllResponse{
				Error: IoError{Error: "err"},
			},
		})
	})
	t.Run("RenameResponse", func(t *testing.T) {
		doTestFileProviderResponse(t, api, FileProviderResponse{
			Uid: uuid.NewString(),
			Response: RenameResponse{
				Error: IoError{Error: "err"},
			},
		})
	})
	t.Run("FileInfoResponse", func(t *testing.T) {
		doTestFileProviderResponse(t, api, FileProviderResponse{
			Uid: uuid.NewString(),
			Response: FileInfoResponse{
				Error:   IoError{Error: "err"},
				Name:    "filename",
				Size:    4212,
				Mode:    0777,
				ModTime: time.Now().Unix(),
				IsDir:   true,
				Last:    true,
			},
		})
	})

	//File Provider File Requests

	t.Run("FileCloseRequest", func(t *testing.T) {
		doTestFileProviderFileRequest(t, api, FileProviderFileRequest{
			Uid:     uuid.NewString(),
			FileId:  "some-file",
			Request: FileCloseRequest{},
		})
	})
	t.Run("FileReadRequest", func(t *testing.T) {
		doTestFileProviderFileRequest(t, api, FileProviderFileRequest{
			Uid:    uuid.NewString(),
			FileId: "some-file",
			Request: FileReadRequest{
				Len: 49247,
			},
		})
	})
	t.Run("FileWriteRequest", func(t *testing.T) {
		doTestFileProviderFileRequest(t, api, FileProviderFileRequest{
			Uid:    uuid.NewString(),
			FileId: "some-file",
			Request: FileWriteRequest{
				Payload: []byte{1, 2, 3, 4},
			},
		})
	})
	t.Run("FileSeekRequest", func(t *testing.T) {
		doTestFileProviderFileRequest(t, api, FileProviderFileRequest{
			Uid:    uuid.NewString(),
			FileId: "some-file",
			Request: FileSeekRequest{
				Offset: 5463,
				Whence: io.SeekCurrent,
			},
		})
	})
	t.Run("ReaddirRequest", func(t *testing.T) {
		doTestFileProviderFileRequest(t, api, FileProviderFileRequest{
			Uid:    uuid.NewString(),
			FileId: "some-file",
			Request: ReaddirRequest{
				Count: 15,
			},
		})
	})

	//File Provider File Responses

	t.Run("FileCloseResponse", func(t *testing.T) {
		doTestFileProviderFileResponse(t, api, FileProviderFileResponse{
			Uid: uuid.NewString(),
			Response: FileCloseResponse{
				Error: IoError{Error: "err"},
			},
		})
	})
	t.Run("FileReadResponse", func(t *testing.T) {
		doTestFileProviderFileResponse(t, api, FileProviderFileResponse{
			Uid: uuid.NewString(),
			Response: FileReadResponse{
				Error:   IoError{Error: "err"},
				Payload: []byte{4, 5, 6},
			},
		})
	})
	t.Run("FileSeekResponse", func(t *testing.T) {
		doTestFileProviderFileResponse(t, api, FileProviderFileResponse{
			Uid: uuid.NewString(),
			Response: FileSeekResponse{
				Offset: 53625,
				Error:  IoError{Error: "err"},
			},
		})
	})
	t.Run("FileWriteResponse", func(t *testing.T) {
		doTestFileProviderFileResponse(t, api, FileProviderFileResponse{
			Uid: uuid.NewString(),
			Response: FileWriteResponse{
				Error: IoError{Error: "err"},
				Len:   64,
			},
		})
	})
	t.Run("ReaddirResponse", func(t *testing.T) {
		doTestFileProviderFileResponse(t, api, FileProviderFileResponse{
			Uid: uuid.NewString(),
			Response: ReaddirResponse{
				Error: IoError{Error: "err"},
				Count: 64,
			},
		})
	})
}

func doTestFileProviderRequest(t *testing.T, api avro.API, input FileProviderRequest) {

	data, err := api.Marshal(FileProviderRequestSchema, input)
	if err != nil {
		t.Error(err)
	}

	output := FileProviderRequest{}
	err = api.Unmarshal(FileProviderRequestSchema, data, &output)
	if err != nil {
		t.Error(err)
	}
	assert.Equal(t, input, output)
}

func doTestFileProviderResponse(t *testing.T, api avro.API, input FileProviderResponse) {

	data, err := api.Marshal(FileProviderResponseSchema, input)
	if err != nil {
		t.Error(err)
	}

	output := FileProviderResponse{}
	err = api.Unmarshal(FileProviderResponseSchema, data, &output)
	if err != nil {
		t.Error(err)
	}
	assert.Equal(t, input, output)
}

func doTestFileProviderFileRequest(t *testing.T, api avro.API, input FileProviderFileRequest) {

	data, err := api.Marshal(FileProviderFileRequestSchema, input)
	if err != nil {
		t.Error(err)
	}

	output := FileProviderFileRequest{}
	err = api.Unmarshal(FileProviderFileRequestSchema, data, &output)
	if err != nil {
		t.Error(err)
	}
	assert.Equal(t, input, output)
}

func doTestFileProviderFileResponse(t *testing.T, api avro.API, input FileProviderFileResponse) {

	data, err := api.Marshal(FileProviderFileResponseSchema, input)
	if err != nil {
		t.Error(err)
	}

	output := FileProviderFileResponse{}
	err = api.Unmarshal(FileProviderFileResponseSchema, data, &output)
	if err != nil {
		t.Error(err)
	}
	assert.Equal(t, input, output)
}
