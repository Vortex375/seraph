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
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/nats-io/nats.go"
	"umbasa.net/seraph/messaging"
)

var errNotFound = errors.New("not found")

// serve subscribes fn to topic as a queue handler (so scaled instances share the load). An error
// from fn becomes the response's Error.
func serve[Req, Res any](s *Service, topic string, fn func(context.Context, *Req) (*Res, error)) error {
	sub, err := s.nc.QueueSubscribe(topic, topic, func(msg *nats.Msg) {
		ctx := messaging.ExtractTraceContext(context.Background(), msg)
		ctx, span := s.tracer.Start(ctx, "handle "+topic)
		defer span.End()

		var req Req
		var data []byte
		res, err := (*Res)(nil), json.Unmarshal(msg.Data, &req)
		if err == nil {
			res, err = fn(ctx, &req)
		}
		if err != nil {
			if !errors.Is(err, errNotFound) {
				s.log.Error("request failed", "topic", topic, "error", err)
			}
			data, _ = json.Marshal(map[string]string{"error": err.Error()})
		} else if data, err = json.Marshal(res); err != nil {
			data, _ = json.Marshal(map[string]string{"error": err.Error()})
		}
		msg.Respond(data)
	})
	if err != nil {
		return fmt.Errorf("subscribe %s: %w", topic, err)
	}
	s.subs = append(s.subs, sub)
	return nil
}

func (s *Service) subscribeAPI() error {
	for _, err := range []error{
		serve(s, SearchTopic, s.search),
		serve(s, StatusTopic, s.status),
		serve(s, PeopleTopic, s.people),
		serve(s, PersonRenameTopic, s.renamePerson),
		serve(s, PhotoTopic, s.photoAnalysis),
		serve(s, FaceAssignTopic, s.assignFace),
	} {
		if err != nil {
			for _, sub := range s.subs {
				sub.Unsubscribe()
			}
			s.subs = nil
			return err
		}
	}
	return nil
}

// prefixFilter returns a SQL condition on col("provider_id") / col("path") that holds for rows under
// one of prefixes, appending its parameters to args. No prefixes match nothing. A prefix path
// matches itself and everything below it ("/" is the whole provider); `\`, `%` and `_` in it are
// escaped so they never act as wildcards.
func prefixFilter(prefixes []Prefix, alias string, args []any) (string, []any) {
	if len(prefixes) == 0 {
		return "false", args
	}
	if alias != "" {
		alias += "."
	}
	esc := strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)
	ph := func(v any) string {
		args = append(args, v)
		return "$" + strconv.Itoa(len(args))
	}
	conds := make([]string, 0, len(prefixes))
	for _, p := range prefixes {
		c := alias + "provider_id = " + ph(p.ProviderID)
		if path := strings.TrimRight(p.Path, "/"); path != "" {
			c += " AND (" + alias + "path = " + ph(path) + " OR " + alias + "path LIKE " + ph(esc.Replace(path)+"/%") + ` ESCAPE '\')`
		}
		conds = append(conds, "("+c+")")
	}
	return "(" + strings.Join(conds, " OR ") + ")", args
}

func (s *Service) search(ctx context.Context, req *SearchRequest) (*SearchResponse, error) {
	limit := req.Limit
	if limit <= 0 {
		limit = DefaultSearchLimit
	}
	limit = min(limit, MaxSearchLimit)

	var args []any
	var pred string
	pred, args = prefixFilter(req.Prefixes, "p", args)
	q := `SELECT p.provider_id, p.path, `
	order := `p.seq DESC, p.provider_id, p.path`
	from := ` FROM photos p`
	if req.Text != "" {
		emb, err := s.ml.EmbedText(ctx, req.Text)
		if err != nil {
			return nil, fmt.Errorf("embed query: %w", err)
		}
		args = append(args, vectorLiteral(emb))
		dist := "e.embedding <=> $" + strconv.Itoa(len(args)) + "::text::vector"
		q += "1 - (" + dist + ")"
		from += ` JOIN photo_embeddings e ON e.provider_id = p.provider_id AND e.path = p.path`
		order = dist + ", p.provider_id, p.path"
	} else {
		q += "0"
	}
	q += from + ` WHERE NOT p.deleted AND ` + pred
	if req.Tag != "" {
		args = append(args, req.Tag)
		q += ` AND EXISTS (SELECT 1 FROM photo_tags t WHERE t.provider_id = p.provider_id AND t.path = p.path AND t.tag = $` + strconv.Itoa(len(args)) + `)`
	}
	if req.PersonID != "" {
		args = append(args, req.PersonID)
		q += ` AND EXISTS (SELECT 1 FROM faces f WHERE f.provider_id = p.provider_id AND f.path = p.path AND f.person_id::text = $` + strconv.Itoa(len(args)) + `)`
	}
	args = append(args, limit)
	q += ` ORDER BY ` + order + ` LIMIT $` + strconv.Itoa(len(args))

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	// the tag/person/prefix filters would otherwise leave HNSW scans short (pgvector >= 0.8)
	if _, err := tx.Exec(ctx, `SET LOCAL hnsw.iterative_scan = relaxed_order`); err != nil {
		return nil, err
	}
	rows, err := tx.Query(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("search: %w", err)
	}
	items, err := pgx.CollectRows(rows, pgx.RowToStructByPos[SearchItem])
	if err != nil {
		return nil, fmt.Errorf("search: %w", err)
	}
	if items == nil {
		items = []SearchItem{}
	}
	return &SearchResponse{Items: items}, nil
}

func (s *Service) status(ctx context.Context, req *StatusRequest) (*StatusResponse, error) {
	pred, args := prefixFilter(req.Prefixes, "p", nil)
	res := &StatusResponse{}
	err := s.pool.QueryRow(ctx, `
		SELECT count(*) FILTER (WHERE e.path IS NOT NULL),
		       count(*) FILTER (WHERE e.path IS NULL AND p.error IS NULL),
		       count(*) FILTER (WHERE p.error IS NOT NULL)
		FROM photos p LEFT JOIN photo_embeddings e ON e.provider_id = p.provider_id AND e.path = p.path
		WHERE NOT p.deleted AND `+pred, args...).Scan(&res.Analysed, &res.Pending, &res.Failed)
	if err != nil {
		return nil, fmt.Errorf("status: %w", err)
	}
	return res, nil
}

type querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// visiblePersons lists the persons with a face in a live photo under prefixes (only the person
// onlyID when set): photoCount counts those photos, the cover is the person's cover face if
// visible, else their best-scoring visible face. Named persons first, then by photoCount.
func visiblePersons(ctx context.Context, q querier, prefixes []Prefix, onlyID string) ([]Person, error) {
	pred, args := prefixFilter(prefixes, "f", nil)
	only := ""
	if onlyID != "" {
		args = append(args, onlyID)
		only = ` AND f.person_id::text = $` + strconv.Itoa(len(args))
	}
	rows, err := q.Query(ctx, `
		WITH vis AS (
			SELECT f.id, f.person_id, f.provider_id, f.path, f.score, f.box_x1, f.box_y1, f.box_x2, f.box_y2
			FROM faces f JOIN photos ph ON ph.provider_id = f.provider_id AND ph.path = f.path
			WHERE NOT ph.deleted AND f.person_id IS NOT NULL AND `+pred+only+`),
		cnt AS (SELECT person_id, count(DISTINCT (provider_id, path)) AS n FROM vis GROUP BY person_id),
		cov AS (
			SELECT DISTINCT ON (v.person_id) v.* FROM vis v JOIN persons p ON p.id = v.person_id
			ORDER BY v.person_id, (v.id = p.cover_face_id) DESC, v.score DESC)
		SELECT p.id::text, coalesce(p.name, ''), cnt.n, cov.provider_id, cov.path, cov.box_x1, cov.box_y1, cov.box_x2, cov.box_y2
		FROM persons p JOIN cnt ON cnt.person_id = p.id JOIN cov ON cov.person_id = p.id
		ORDER BY (p.name IS NOT NULL) DESC, cnt.n DESC, p.id`, args...)
	if err != nil {
		return nil, fmt.Errorf("list persons: %w", err)
	}
	people, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (p Person, err error) {
		err = r.Scan(&p.ID, &p.Name, &p.PhotoCount, &p.Cover.ProviderID, &p.Cover.Path,
			&p.Cover.Box.X1, &p.Cover.Box.Y1, &p.Cover.Box.X2, &p.Cover.Box.Y2)
		return
	})
	if err != nil {
		return nil, fmt.Errorf("list persons: %w", err)
	}
	if people == nil {
		people = []Person{}
	}
	return people, nil
}

func (s *Service) people(ctx context.Context, req *PeopleRequest) (*PeopleResponse, error) {
	people, err := visiblePersons(ctx, s.pool, req.Prefixes, "")
	if err != nil {
		return nil, err
	}
	return &PeopleResponse{People: people}, nil
}

func (s *Service) renamePerson(ctx context.Context, req *PersonRenameRequest) (*PersonResponse, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	if req.ID == "" {
		return nil, errNotFound
	}
	people, err := visiblePersons(ctx, tx, req.Prefixes, req.ID)
	if err != nil {
		return nil, err
	}
	if len(people) == 0 {
		return nil, errNotFound
	}
	var name *string
	if req.Name != "" {
		name = &req.Name
	}
	if _, err := tx.Exec(ctx, `UPDATE persons SET name = $2 WHERE id::text = $1`, req.ID, name); err != nil {
		return nil, fmt.Errorf("rename person: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	people[0].Name = req.Name
	return &PersonResponse{Person: &people[0]}, nil
}

const faceColumns = `f.id::text, f.box_x1, f.box_y1, f.box_x2, f.box_y2, coalesce(f.person_id::text, ''), coalesce(pe.name, ''), f.manual`

func scanFace(r pgx.CollectableRow) (f PhotoFace, err error) {
	err = r.Scan(&f.ID, &f.Box.X1, &f.Box.Y1, &f.Box.X2, &f.Box.Y2, &f.PersonID, &f.PersonName, &f.Manual)
	return
}

func (s *Service) photoAnalysis(ctx context.Context, req *PhotoRequest) (*PhotoResponse, error) {
	pred, args := prefixFilter(req.Prefixes, "p", []any{req.ProviderID, req.Path})
	res := &PhotoResponse{Tags: []PhotoTag{}, Faces: []PhotoFace{}}
	var errText *string
	err := s.pool.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM photo_embeddings e WHERE e.provider_id = p.provider_id AND e.path = p.path), p.error
		FROM photos p WHERE p.provider_id = $1 AND p.path = $2 AND NOT p.deleted AND `+pred, args...).Scan(&res.Analysed, &errText)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, errNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("read photo: %w", err)
	}
	if errText != nil {
		res.AnalysisError = *errText
	}

	rows, err := s.pool.Query(ctx, `SELECT tag, score FROM photo_tags WHERE provider_id = $1 AND path = $2 ORDER BY score DESC, tag`, req.ProviderID, req.Path)
	if err != nil {
		return nil, fmt.Errorf("read tags: %w", err)
	}
	if res.Tags, err = pgx.CollectRows(rows, pgx.RowToStructByPos[PhotoTag]); err != nil {
		return nil, fmt.Errorf("read tags: %w", err)
	}
	rows, err = s.pool.Query(ctx, `
		SELECT `+faceColumns+` FROM faces f LEFT JOIN persons pe ON pe.id = f.person_id
		WHERE f.provider_id = $1 AND f.path = $2 ORDER BY f.score DESC, f.id`, req.ProviderID, req.Path)
	if err != nil {
		return nil, fmt.Errorf("read faces: %w", err)
	}
	if res.Faces, err = pgx.CollectRows(rows, scanFace); err != nil {
		return nil, fmt.Errorf("read faces: %w", err)
	}
	return res, nil
}

func (s *Service) assignFace(ctx context.Context, req *FaceAssignRequest) (*FaceResponse, error) {
	set := 0
	for _, b := range []bool{req.PersonID != "", req.NewPersonName != "", req.Unassign} {
		if b {
			set++
		}
	}
	if set != 1 {
		return nil, errors.New("exactly one of personId, newPersonName and unassign must be set")
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, clusterLockKey); err != nil {
		return nil, err
	}

	// the face's photo must be visible; re-read under the lock
	pred, args := prefixFilter(req.Prefixes, "f", []any{req.FaceID})
	var old *string
	err = tx.QueryRow(ctx, `
		SELECT f.person_id::text FROM faces f JOIN photos ph ON ph.provider_id = f.provider_id AND ph.path = f.path
		WHERE f.id::text = $1 AND NOT ph.deleted AND `+pred, args...).Scan(&old)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, errNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("read face: %w", err)
	}

	var target *string
	switch {
	case req.PersonID != "":
		people, err := visiblePersons(ctx, tx, req.Prefixes, req.PersonID)
		if err != nil {
			return nil, err
		}
		if len(people) == 0 {
			return nil, errNotFound
		}
		target = &people[0].ID
	case req.NewPersonName != "":
		var id string
		if err := tx.QueryRow(ctx, `INSERT INTO persons (name, cover_face_id) VALUES ($1, $2::uuid) RETURNING id::text`, req.NewPersonName, req.FaceID).Scan(&id); err != nil {
			return nil, fmt.Errorf("create person: %w", err)
		}
		target = &id
	}

	if _, err := tx.Exec(ctx, `UPDATE faces SET person_id = $2, manual = true, deferred = false, clustered = true WHERE id::text = $1`, req.FaceID, target); err != nil {
		return nil, fmt.Errorf("assign face: %w", err)
	}
	if old != nil && (target == nil || *target != *old) {
		if _, err := tx.Exec(ctx, `UPDATE persons SET cover_face_id = NULL WHERE id::text = $1 AND cover_face_id::text = $2`, *old, req.FaceID); err != nil {
			return nil, fmt.Errorf("uncover person: %w", err)
		}
		if err := cleanupPersons(ctx, tx, []string{*old}); err != nil {
			return nil, err
		}
	}

	rows, err := tx.Query(ctx, `SELECT `+faceColumns+` FROM faces f LEFT JOIN persons pe ON pe.id = f.person_id WHERE f.id::text = $1`, req.FaceID)
	if err != nil {
		return nil, fmt.Errorf("read face: %w", err)
	}
	face, err := pgx.CollectOneRow(rows, scanFace)
	if err != nil {
		return nil, fmt.Errorf("read face: %w", err)
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, err
	}
	if target != nil {
		s.clusterDirty.Store(true)
	}
	return &FaceResponse{Face: &face}, nil
}
