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

const FileInfoStream = "SERAPH_FILE_INFO"
const FileProviderFileInfoTopic = "seraph.fileprovider.*.fileinfo"
const FileProviderFileInfoTopicPattern = "seraph.fileprovider.%s.fileinfo"

// FileRemovedStream reuses the FileInfoStream so the file-indexer's single
// JetStream consumer reads both FileInfoEvent and FileRemovedEvent from one
// durable; the consumer branches on the message subject. Carrying the
// removal signal on the same stream keeps ordering between a file's last
// FileInfoEvent and its removal within a provider's subject, which a
// separate stream could not guarantee.
const FileProviderFileRemovedTopic = "seraph.fileprovider.*.fileremoved"
const FileProviderFileRemovedTopicPattern = "seraph.fileprovider.%s.fileremoved"

const FileChangedStream = "SERAPH_FILE_CHANGED"
const FileChangedTopic = "seraph.file.*.changed"
const FileChangedTopicPattern = "seraph.file.%s.changed"

const JobsStream = "SERAPH_JOBS"
const JobsTopic = "seraph.jobs.>"
const JobsTopicPattern = "seraph.jobs.%s"

const SpaceChangedStream = "SERAPH_SPACES_CHANGED"
const SpaceChangedTopic = "seraph.spaces.*.changed"
const SpaceChangedTopicPattern = "seraph.spaces.%s.changed"

const SearchRequestTopic = "seraph.search"
const SearchAckTopicPattern = "seraph.search.%s.ack"
const SearchReplyTopicPattern = "seraph.search.%s.reply"

const FileIndexListRequestTopic = "seraph.fileindex.list"
const FileIndexListAckTopicPattern = "seraph.fileindex.list.%s.ack"
const FileIndexListReplyTopicPattern = "seraph.fileindex.list.%s.reply"

// ThumbnailWarmStream/Topic is the durable JetStream work queue for
// background Thumbnail pre-generation ("warming"). Publishers (e.g. the
// gallery service, as photos enter its read model) publish
// ThumbnailWarmRequest fire-and-forget; the thumbnailer consumes it with its
// own, smaller-than-interactive concurrency budget and acks only once a
// Thumbnail has actually been produced (or the item is durably
// undecodable) - see ThumbnailWarmRequest's docs for why this is a
// durable queue and not core-NATS request/reply.
const ThumbnailWarmStream = "SERAPH_THUMBNAIL_WARM"
const ThumbnailWarmTopic = "seraph.thumbnail.warm"

// ThumbnailWarmUnsupportedStream/Topic is the durable JetStream work queue
// the thumbnailer uses to report a warm request it could not decode back to
// the publisher's read model - see ThumbnailWarmUnsupportedNotice's docs.
const ThumbnailWarmUnsupportedStream = "SERAPH_THUMBNAIL_WARM_UNSUPPORTED"
const ThumbnailWarmUnsupportedTopic = "seraph.thumbnail.warm.unsupported"
