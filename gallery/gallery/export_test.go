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

package gallery

import (
	"context"
	"time"

	"go.mongodb.org/mongo-driver/bson/primitive"
)

// SetPrefixCacheRetryInterval shortens the prefix cache retry for tests and
// returns a func restoring the previous value.
func SetPrefixCacheRetryInterval(d time.Duration) func() {
	prev := prefixCacheRetryInterval
	prefixCacheRetryInterval = d
	return func() { prefixCacheRetryInterval = prev }
}

// RunPhotoReplay runs one photo replay pass synchronously.
func (g *GalleryProvider) RunPhotoReplay(ctx context.Context) error {
	return g.runPhotoReplay(ctx)
}

// HealPendingMetadata runs one metadata heal pass over a physical prefix.
func (g *GalleryProvider) HealPendingMetadata(ctx context.Context, folderId primitive.ObjectID, providerId, path string) error {
	return g.healPendingMetadata(ctx, folderId, prefix{providerId: providerId, path: path})
}
