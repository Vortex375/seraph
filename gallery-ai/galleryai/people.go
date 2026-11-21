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
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"umbasa.net/seraph/messaging"
)

// clusterLockKey is the Postgres advisory lock every clustering step runs under.
// ponytail: one global lock, as Immich does; per-region locks if clustering throughput ever matters.
const clusterLockKey = 0x5e7a0f05

// clusterFaces clusters the unassigned, non-manual faces that match where (a SQL
// condition over faces, with args), one transaction each. pass is false right
// after a photo was stored, true for the periodic full pass (see clusterFace).
// job (may be nil) gets the progress of the run.
func (s *Service) clusterFaces(ctx context.Context, job *messaging.Job, pass bool, where string, args ...any) error {
	rows, err := s.pool.Query(ctx, `SELECT id FROM faces WHERE person_id IS NULL AND NOT manual AND (`+where+`) ORDER BY id`, args...)
	if err != nil {
		return fmt.Errorf("list faces to cluster: %w", err)
	}
	ids, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return fmt.Errorf("list faces to cluster: %w", err)
	}
	total := int64(len(ids))
	if job != nil {
		job.Progress(0, total, fmt.Sprintf("0 of %d faces", total))
	}
	for i, id := range ids {
		if err := s.clusterFace(ctx, id, pass); err != nil {
			return fmt.Errorf("cluster face %s: %w", id, err)
		}
		if job != nil {
			job.Progress(int64(i+1), total, fmt.Sprintf("%d of %d faces", i+1, total))
		}
	}
	return nil
}

// clusterPass re-processes every face without a person, so a face that arrived
// before its person existed (gradual imports) still gets attached. This also
// covers faces never clustered (crash, or failure after the photo was stored).
// A failed pass re-arms clusterDirty.
func (s *Service) clusterPass(ctx context.Context) error {
	job := messaging.NewJob(s.nc, "gallery-ai.clustering", "Face clustering")
	defer job.Close()
	err := s.clusterFaces(ctx, job, true, `true`)
	switch {
	case err == nil:
		job.Complete("Face clustering finished")
	case ctx.Err() == nil:
		job.Fail(err)
	}
	if err != nil {
		s.clusterDirty.Store(true)
	}
	return err
}

// clusterTick runs a full pass only if a face was assigned (or a person created)
// since the previous one, or on the first call; it reports whether it ran.
// ponytail: in-memory flag, so each instance redoes one full pass at startup; fine until the library is huge.
func (s *Service) clusterTick(ctx context.Context) bool {
	if !s.clusterDirty.Swap(false) {
		return false
	}
	if err := s.clusterPass(ctx); err != nil && ctx.Err() == nil {
		s.log.Error("face clustering pass failed", "error", err)
	}
	return true
}

// clusterLoop ticks at startup and then every DeferredInterval.
func (s *Service) clusterLoop(ctx context.Context) {
	defer s.wg.Done()
	for {
		s.clusterTick(ctx)
		select {
		case <-ctx.Done():
			return
		case <-time.After(s.cfg.DeferredInterval):
		}
	}
}

// clusterFace is Immich's handleRecognizeFaces for one face (spec "People clustering").
// A non-core face is deferred on arrival (pass false); in a pass it may only join an existing person.
func (s *Service) clusterFace(ctx context.Context, id string, pass bool) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, clusterLockKey); err != nil {
		return err
	}

	// re-check under the lock: the face may be gone, assigned or taken over manually meanwhile
	var one int
	err = tx.QueryRow(ctx, `SELECT 1 FROM faces WHERE id = $1 AND person_id IS NULL AND NOT manual`, id).Scan(&one)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	// the person/manual filters below would otherwise leave HNSW scans short on big libraries (pgvector >= 0.8)
	if _, err := tx.Exec(ctx, `SET LOCAL hnsw.iterative_scan = relaxed_order`); err != nil {
		return err
	}

	// the face's nearest neighbours within maxDistance, itself first; manual and unassigned faces count
	rows, err := tx.Query(ctx, `
		SELECT id::text, person_id::text FROM faces
		WHERE embedding <=> (SELECT embedding FROM faces WHERE id = $1) <= $2
		ORDER BY embedding <=> (SELECT embedding FROM faces WHERE id = $1) LIMIT $3`, id, s.cfg.MaxDistance, s.cfg.MinFaces)
	if err != nil {
		return err
	}
	type match struct {
		id     string
		person *string
	}
	matches, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (m match, err error) {
		err = r.Scan(&m.id, &m.person)
		return
	})
	if err != nil {
		return err
	}

	done := func(person *string, deferred bool) error {
		if _, err := tx.Exec(ctx, `UPDATE faces SET person_id = $2, deferred = $3, clustered = true WHERE id = $1`, id, person, deferred); err != nil {
			return err
		}
		if person != nil {
			s.clusterDirty.Store(true)
		}
		return tx.Commit(ctx)
	}

	// a face with no neighbour is simply non-core: deferred once (so it can still join a person
	// created meanwhile by its later neighbours), then left unassigned
	isCore := len(matches) >= s.cfg.MinFaces
	if !isCore && !pass {
		return done(nil, true)
	}

	var person *string
	for _, m := range matches {
		if m.person != nil {
			person = m.person
			break
		}
	}
	if person == nil {
		err := tx.QueryRow(ctx, `
			SELECT person_id::text FROM faces
			WHERE person_id IS NOT NULL AND embedding <=> (SELECT embedding FROM faces WHERE id = $1) <= $2
			ORDER BY embedding <=> (SELECT embedding FROM faces WHERE id = $1) LIMIT 1`, id, s.cfg.MaxDistance).Scan(&person)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
	}
	if person == nil && isCore {
		var pid string
		if err := tx.QueryRow(ctx, `INSERT INTO persons (cover_face_id) VALUES ($1) RETURNING id::text`, id).Scan(&pid); err != nil {
			return err
		}
		person = &pid
	}
	return done(person, false)
}
