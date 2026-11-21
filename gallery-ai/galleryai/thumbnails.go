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

package galleryai

import (
	"context"
	"fmt"
	"io"
	"os"

	"github.com/nats-io/nats.go"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/thumbnailer/thumbnailer"
)

const thumbnailSize = 512

// ThumbnailSource returns the 512 px Thumbnail bytes of a physical photo.
// Unsupported, corrupt and oversized photos must come back as permanent errors.
type ThumbnailSource interface {
	Thumbnail(ctx context.Context, providerID, path string) ([]byte, error)
}

type natsThumbnails struct {
	nc     *nats.Conn
	logger *logging.Logger
}

func NewThumbnailSource(nc *nats.Conn, logger *logging.Logger) ThumbnailSource {
	return &natsThumbnails{nc: nc, logger: logger}
}

func (n *natsThumbnails) Thumbnail(ctx context.Context, providerID, path string) ([]byte, error) {
	req := thumbnailer.ThumbnailRequest{ProviderID: providerID, Path: path, Width: thumbnailSize, Height: thumbnailSize}
	resp := thumbnailer.ThumbnailResponse{}
	if err := messaging.Request(ctx, n.nc, thumbnailer.ThumbnailRequestTopic, &req, &resp); err != nil {
		return nil, fmt.Errorf("thumbnail request: %w", err)
	}
	if resp.Error != "" {
		err := fmt.Errorf("thumbnailer: %s", resp.Error)
		switch resp.ErrorClass {
		case thumbnailer.ErrorClassUnsupportedFormat, thumbnailer.ErrorClassCorrupt, thumbnailer.ErrorClassTooLarge:
			return nil, permanent(err)
		}
		return nil, err
	}

	client := fileprovider.NewFileProviderClient(resp.ProviderID, n.nc, n.logger)
	defer client.Close()
	file, err := client.OpenFile(ctx, resp.Path, os.O_RDONLY, 0)
	if err != nil {
		return nil, fmt.Errorf("open thumbnail: %w", err)
	}
	defer file.Close()

	data, err := io.ReadAll(file)
	if err != nil {
		return nil, fmt.Errorf("read thumbnail: %w", err)
	}
	return data, nil
}
