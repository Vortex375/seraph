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

const FileChangedStream = "SERAPH_FILE_CHANGED"
const FileChangedTopic = "seraph.file.*.changed"
const FileChangedTopicPattern = "seraph.file.%s.changed"

const JobsStream = "SERAPH_JOBS"
const JobsTopic = "seraph.jobs.>"
const JobsTopicPattern = "seraph.jobs.%s"

const SearchRequestTopic = "seraph.search"
const SearchAckTopicPattern = "seraph.search.%s.ack"
const SearchReplyTopicPattern = "seraph.search.%s.reply"
