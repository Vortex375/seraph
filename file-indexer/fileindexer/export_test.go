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

package fileindexer

import (
	"context"

	"umbasa.net/seraph/events"
)

// Exported for tests only: lets the integration test run explain() against
// the exact filter and sort the production query path uses, so the query
// plan assertion cannot drift away from the real query.
var (
	BuildPrefixSelfFilter  = buildPrefixSelfFilter
	BuildDescendantsFilter = buildDescendantsFilter
	ListSort               = listSort
)

// Exported for tests only: lets the removal-signal integration test drive
// the readdir-complete path directly to assert it is a no-op for files a
// prior removal signal already deleted, without having to synthesize a full
// FileInfoEvent/readdir sequence through the consumer.
func ConsumerHandleReaddirComplete(c Consumer, ctx context.Context, file *File, readDir *events.ReadDir) error {
	return c.(*consumer).handleReaddirComplete(ctx, file, readDir)
}
