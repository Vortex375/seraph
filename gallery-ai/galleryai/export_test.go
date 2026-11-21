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
	"time"
)

func SetRetryDelay(s *Service, d time.Duration) { s.retryDelay = d }

func PermanentForTest(err error) error { return permanent(err) }

func SetTagRetryDelay(s *Service, d time.Duration) { s.tagRetryDelay = d }

func SetBeforeTagStateWrite(s *Service, f func()) { s.beforeTagStateWrite = f }

func ClusterPass(s *Service, ctx context.Context) error { return s.clusterPass(ctx) }

// ClusterTick runs the gated periodic step and reports whether it ran a pass.
func ClusterTick(s *Service, ctx context.Context) bool { return s.clusterTick(ctx) }
