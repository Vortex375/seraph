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

package events

const (
	GalleryPhotoUpserted = "upserted"
	GalleryPhotoDeleted  = "deleted"
)

// GalleryPhotoChangedEvent tells consumers that a photo entered, changed in
// or left the gallery read model. It is published fire-and-forget onto
// GalleryPhotoChangedTopic, a durable JetStream work queue, for the same
// silent-loss reasons ThumbnailWarmRequest documents.
//
// ProviderID/Path are PHYSICAL coordinates, like ThumbnailWarmRequest. Seq
// is the photo's gallery seq after the write; consumers drop an event whose
// Seq is not newer than what they have already processed for that photo, so
// redelivery, replay and reordering are all harmless.
type GalleryPhotoChangedEvent struct {
	ProviderID string `json:"providerId"`
	Path       string `json:"path"`
	Change     string `json:"change"`
	Seq        int64  `json:"seq"`
}
