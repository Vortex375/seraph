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
	"log/slog"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/nats-io/nats.go/jetstream"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/fx"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/tracing"
	"umbasa.net/seraph/util"
)

// consumerName is the durable JetStream consumer gallery-ai uses on
// events.GalleryPhotoChangedStream, fixed so the position survives restarts.
const consumerName = "SERAPH_GALLERY_AI"

// defaultRetryDelay is how long a transiently failed message waits before
// JetStream redelivers it.
const defaultRetryDelay = 30 * time.Second

type Params struct {
	fx.In

	Config  Config
	Pool    *pgxpool.Pool
	ML      *MLClient
	Thumbs  ThumbnailSource
	Js      jetstream.JetStream
	Logger  *logging.Logger
	Tracing *tracing.Tracing
}

type Service struct {
	cfg        Config
	pool       *pgxpool.Pool
	ml         *MLClient
	thumbs     ThumbnailSource
	js         jetstream.JetStream
	log        *slog.Logger
	tracer     trace.Tracer
	retryDelay time.Duration

	iter   jetstream.MessagesContext
	cancel context.CancelFunc
	wg     sync.WaitGroup
}

func New(p Params) *Service {
	return &Service{
		cfg:        p.Config,
		pool:       p.Pool,
		ml:         p.ML,
		thumbs:     p.Thumbs,
		js:         p.Js,
		log:        p.Logger.GetLogger("gallery-ai"),
		tracer:     p.Tracing.TracerProvider.Tracer("gallery-ai"),
		retryDelay: defaultRetryDelay,
	}
}

// Start creates (or reattaches to) the durable consumer and processes events
// in the background.
func (s *Service) Start() error {
	ctx, cancel := context.WithCancel(context.Background())

	stream, err := s.js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
		Name:      events.GalleryPhotoChangedStream,
		Subjects:  []string{events.GalleryPhotoChangedTopic},
		Retention: jetstream.WorkQueuePolicy,
	})
	if err != nil {
		cancel()
		return fmt.Errorf("create/update %s stream: %w", events.GalleryPhotoChangedStream, err)
	}

	cons, err := stream.CreateOrUpdateConsumer(ctx, jetstream.ConsumerConfig{
		Durable:       consumerName,
		AckPolicy:     jetstream.AckExplicitPolicy,
		MaxAckPending: s.cfg.MaxAckPending,
	})
	if err != nil {
		cancel()
		return fmt.Errorf("create/update %s consumer: %w", consumerName, err)
	}

	s.iter, err = cons.Messages()
	if err != nil {
		cancel()
		return fmt.Errorf("start consuming %s: %w", consumerName, err)
	}
	s.cancel = cancel

	s.wg.Add(2)
	go s.loop(ctx)
	go func() {
		defer s.wg.Done()
		s.sweep(ctx)
	}()
	return nil
}

func (s *Service) Stop() {
	s.cancel()
	s.iter.Stop()
	s.wg.Wait()
}

// loop dispatches each message to its own goroutine, never holding more than
// MaxAckPending of them at once (the ML call is the bottleneck).
func (s *Service) loop(ctx context.Context) {
	defer s.wg.Done()
	dispatch := util.NewLimiter(max(s.cfg.MaxAckPending, 1))

	for {
		if !dispatch.Begin(ctx) {
			return
		}
		msg, err := s.iter.Next()
		if err != nil {
			dispatch.End()
			if !errors.Is(err, jetstream.ErrMsgIteratorClosed) {
				s.log.Error("photo changed consumer error", "error", err)
			}
			return
		}
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			defer dispatch.End()
			s.handleMessage(ctx, msg)
		}()
	}
}

// handleMessage acks when the event is handled or can never succeed, and
// naks with a delay on transient failure (thumbnailer or ML server down,
// ML 5xx, database error) so JetStream redelivers it.
func (s *Service) handleMessage(ctx context.Context, msg jetstream.Msg) {
	ev := events.GalleryPhotoChangedEvent{}
	if err := json.Unmarshal(msg.Data(), &ev); err != nil || ev.ProviderID == "" || ev.Path == "" {
		s.log.Error("invalid GalleryPhotoChangedEvent", "error", err)
		msg.Ack()
		return
	}

	ctx, span := s.tracer.Start(ctx, "photo changed "+ev.Change)
	defer span.End()

	if err := s.handle(ctx, ev); err != nil {
		s.log.Error("photo analysis failed; will retry", "provider", ev.ProviderID, "path", ev.Path, "error", err)
		msg.NakWithDelay(s.retryDelay)
		return
	}
	msg.Ack()
}

func (s *Service) handle(ctx context.Context, ev events.GalleryPhotoChangedEvent) error {
	switch ev.Change {
	case events.GalleryPhotoUpserted:
		return s.upserted(ctx, ev)
	case events.GalleryPhotoDeleted:
		return s.store(ctx, ev, true, false, nil, "")
	default:
		s.log.Error("unknown change in GalleryPhotoChangedEvent", "change", ev.Change)
		return nil
	}
}

func (s *Service) upserted(ctx context.Context, ev events.GalleryPhotoChangedEvent) error {
	// cheap staleness check first so a replayed event costs no ML call
	var stored int64
	err := s.pool.QueryRow(ctx, `SELECT seq FROM photos WHERE provider_id = $1 AND path = $2`, ev.ProviderID, ev.Path).Scan(&stored)
	if err == nil && stored >= ev.Seq {
		return nil
	}
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("read photo: %w", err)
	}
	return s.analyseAndStore(ctx, ev, false)
}

// analyseAndStore runs the ML analysis for ev and stores the outcome. rescan
// is set by the model-version sweep, see store.
func (s *Service) analyseAndStore(ctx context.Context, ev events.GalleryPhotoChangedEvent, rescan bool) error {
	img, err := s.thumbs.Thumbnail(ctx, ev.ProviderID, ev.Path)
	var analysis *Analysis
	if err == nil {
		analysis, err = s.ml.Analyse(ctx, img)
	}
	if err != nil {
		if isPermanent(err) {
			s.log.Warn("photo cannot be analysed", "provider", ev.ProviderID, "path", ev.Path, "error", err)
			return s.store(ctx, ev, false, rescan, nil, err.Error())
		}
		return err
	}
	return s.store(ctx, ev, false, rescan, analysis, "")
}

// store applies one event in a single transaction: it upserts the photos row
// unless a newer (or, for upserts, equal) seq is already stored, then replaces
// the photo's embedding, tags and faces. A nil analysis leaves the photo with
// none of them (tombstone, or recorded error). rescan additionally accepts an
// equal seq for a live photo stored under a different model, so the sweep can
// re-analyse at the stored seq; a newer stored seq (or a tombstone) still wins.
func (s *Service) store(ctx context.Context, ev events.GalleryPhotoChangedEvent, deleted, rescan bool, a *Analysis, errText string) error {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)

	var model *string
	var analysedAt *time.Time
	var errCol *string
	switch {
	case deleted:
	case a == nil:
		model, errCol = &s.cfg.ClipModel, &errText
	default:
		now := time.Now()
		model, analysedAt = &s.cfg.ClipModel, &now
	}

	// the row lock taken here also serialises concurrent events for one photo
	tag, err := tx.Exec(ctx, `
		INSERT INTO photos (provider_id, path, seq, deleted, model, analysed_at, error)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (provider_id, path) DO UPDATE SET
			seq = EXCLUDED.seq, deleted = EXCLUDED.deleted, model = EXCLUDED.model,
			analysed_at = EXCLUDED.analysed_at, error = EXCLUDED.error
		WHERE photos.seq < EXCLUDED.seq OR (EXCLUDED.deleted AND photos.seq = EXCLUDED.seq)
			OR ($8 AND photos.seq = EXCLUDED.seq AND NOT photos.deleted AND photos.model IS DISTINCT FROM EXCLUDED.model)`,
		ev.ProviderID, ev.Path, ev.Seq, deleted, model, analysedAt, errCol, rescan)
	if err != nil {
		return fmt.Errorf("upsert photo: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return nil // stale
	}

	for _, table := range []string{"photo_embeddings", "photo_tags"} {
		if _, err := tx.Exec(ctx, `DELETE FROM `+table+` WHERE provider_id = $1 AND path = $2`, ev.ProviderID, ev.Path); err != nil {
			return fmt.Errorf("delete %s: %w", table, err)
		}
	}
	rows, err := tx.Query(ctx, `DELETE FROM faces WHERE provider_id = $1 AND path = $2 RETURNING person_id`, ev.ProviderID, ev.Path)
	if err != nil {
		return fmt.Errorf("delete faces: %w", err)
	}
	personIDs, err := pgx.CollectRows(rows, pgx.RowTo[*string])
	if err != nil {
		return fmt.Errorf("delete faces: %w", err)
	}

	if a != nil {
		if _, err := tx.Exec(ctx, `INSERT INTO photo_embeddings (provider_id, path, embedding) VALUES ($1, $2, $3::text::vector)`,
			ev.ProviderID, ev.Path, vectorLiteral(a.Embedding)); err != nil {
			return fmt.Errorf("insert embedding: %w", err)
		}
		for _, f := range a.Faces {
			if _, err := tx.Exec(ctx, `
				INSERT INTO faces (provider_id, path, box_x1, box_y1, box_x2, box_y2, score, embedding)
				VALUES ($1, $2, $3, $4, $5, $6, $7, $8::text::vector)`,
				ev.ProviderID, ev.Path, f.X1, f.Y1, f.X2, f.Y2, f.Score, vectorLiteral(f.Embedding)); err != nil {
				return fmt.Errorf("insert face: %w", err)
			}
		}
	}

	// persons that lost faces: drop the empty ones, re-cover the rest
	var affected []string
	for _, id := range personIDs {
		if id != nil {
			affected = append(affected, *id)
		}
	}
	if len(affected) > 0 {
		if _, err := tx.Exec(ctx, `
			DELETE FROM persons p WHERE p.id::text = ANY($1)
			AND NOT EXISTS (SELECT 1 FROM faces f WHERE f.person_id = p.id)`, affected); err != nil {
			return fmt.Errorf("delete empty persons: %w", err)
		}
		if _, err := tx.Exec(ctx, `
			UPDATE persons p SET cover_face_id =
				(SELECT f.id FROM faces f WHERE f.person_id = p.id ORDER BY f.score DESC LIMIT 1)
			WHERE p.id::text = ANY($1) AND p.cover_face_id IS NULL`, affected); err != nil {
			return fmt.Errorf("re-cover persons: %w", err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	// tickets 04/05 (tagging, face clustering) hook in here, after commit
	return nil
}

// sweepBatch is how many stale-model photos the sweep loads per query.
const sweepBatch = 100

// sweep re-analyses live photos whose stored model differs from the configured
// CLIP model, sequentially in keyset-paged batches. It runs concurrently with
// the consumer; store's seq conditions keep it from overwriting newer events.
// A transient failure (ML or thumbnailer down) ends the sweep; the next start
// picks the remaining photos up again.
func (s *Service) sweep(ctx context.Context) {
	var lastProvider, lastPath string
	done := 0
	for {
		rows, err := s.pool.Query(ctx, `
			SELECT provider_id, path, seq FROM photos
			WHERE NOT deleted AND model IS DISTINCT FROM $1 AND (provider_id, path) > ($2, $3)
			ORDER BY provider_id, path LIMIT $4`, s.cfg.ClipModel, lastProvider, lastPath, sweepBatch)
		if err != nil {
			s.log.Error("model sweep query failed", "error", err)
			return
		}
		batch, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (events.GalleryPhotoChangedEvent, error) {
			ev := events.GalleryPhotoChangedEvent{Change: events.GalleryPhotoUpserted}
			err := r.Scan(&ev.ProviderID, &ev.Path, &ev.Seq)
			return ev, err
		})
		if err != nil {
			s.log.Error("model sweep query failed", "error", err)
			return
		}
		if len(batch) == 0 {
			if done > 0 {
				s.log.Info("model sweep finished", "model", s.cfg.ClipModel, "photos", done)
			}
			return
		}
		for _, ev := range batch {
			if ctx.Err() != nil {
				return
			}
			if err := s.analyseAndStore(ctx, ev, true); err != nil {
				if ctx.Err() == nil {
					s.log.Error("model sweep aborted", "provider", ev.ProviderID, "path", ev.Path, "error", err)
				}
				return
			}
			done++
		}
		last := batch[len(batch)-1]
		lastProvider, lastPath = last.ProviderID, last.Path
	}
}
