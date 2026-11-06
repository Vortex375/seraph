// Copyright © 2026 Benjamin Schmitz

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

package audiometadata

import (
	"context"
	"fmt"

	"github.com/nats-io/nats.go"
	"umbasa.net/seraph/messaging"
)

// Error is a failed request's answer: Class is one of the ErrorClass values
// ("" for errors that have none, e.g. an invalid request).
type Error struct {
	Class   string
	Message string
}

func (e *Error) Error() string {
	return fmt.Sprintf("audio-metadata: %s (%s)", e.Message, e.Class)
}

// ReadPicture reads path's whole cover picture, in MaxPictureChunk chunks.
// A failure the service reports is an *Error.
func ReadPicture(ctx context.Context, nc *nats.Conn, providerId string, path string) (data []byte, mimeType string, err error) {
	for {
		req := PictureRequest{
			ProviderID: providerId,
			Path:       path,
			Offset:     int64(len(data)),
			Length:     MaxPictureChunk,
		}
		resp := PictureResponse{}
		if err := messaging.Request(ctx, nc, PictureRequestTopic, &req, &resp); err != nil {
			return nil, "", err
		}
		if resp.Error != "" {
			return nil, "", &Error{Class: resp.ErrorClass, Message: resp.Error}
		}
		if data == nil {
			data = make([]byte, 0, resp.TotalSize)
		}
		data = append(data, resp.Data...)
		// an empty chunk ends the loop even if TotalSize is off
		if int64(len(data)) >= resp.TotalSize || len(resp.Data) == 0 {
			return data, resp.MimeType, nil
		}
	}
}
