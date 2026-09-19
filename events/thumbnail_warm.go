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

// ThumbnailWarmRequest asks the thumbnailer to pre-generate a Thumbnail at
// the thumbnailer's configured warm size, in the background, for a photo
// that just entered a read model (e.g. the gallery service's).
//
// This is published fire-and-forget onto ThumbnailWarmTopic, a DURABLE
// JetStream work queue - deliberately NOT the thumbnailer's existing
// core-NATS request/reply preview topic. A publisher that fired eight
// thousand of these as core-NATS requests would time out replies, breach
// the pending-message limit, and have core NATS silently drop the overflow,
// leaving no record of which Thumbnails were never made. A durable work
// queue instead holds every request until a consumer explicitly acks it,
// so redelivery (after a thumbnailer restart, or an ack that never
// happened) is the failure mode, not silent loss.
//
// ProviderID/Path are the PHYSICAL file provider id and path - the same
// coordinates the thumbnailer's interactive ThumbnailRequest uses via
// fileprovider.NewFileProviderClient - not a Space-relative path.
//
// Re-dispatching the same (ProviderID, Path) is harmless: thumbnail
// creation is idempotent (the interactive path already treats "Thumbnail
// already exists" as success), so redelivery or a duplicate dispatch from
// re-ingesting the same file produces no observable difference.
type ThumbnailWarmRequest struct {
	ProviderID string `json:"providerId"`
	Path       string `json:"path"`
}

// ThumbnailWarmUnsupportedNotice is published by the thumbnailer, fire-and-
// forget onto ThumbnailWarmUnsupportedTopic (another durable JetStream work
// queue, for the same silent-loss reasons ThumbnailWarmRequest documents),
// when a warm request could not be decoded at all. It carries the failure
// back to the service that owns the read model (the gallery service) so the
// item can be marked rather than silently left thumbnail-less with no
// record of why.
//
// Reason is one of the owning read model's own "cannot decode" vocabulary
// (for the gallery service, gallery.UnsupportedReasonFormat /
// gallery.UnsupportedReasonCorrupt) - the thumbnailer does not invent a
// second vocabulary, it reuses the caller's.
type ThumbnailWarmUnsupportedNotice struct {
	ProviderID string `json:"providerId"`
	Path       string `json:"path"`
	Reason     string `json:"reason"`
}
