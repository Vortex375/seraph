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
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"umbasa.net/seraph/messaging"
)

// TagConfig is one zero-shot content tag: a photo gets the tag when its CLIP
// image embedding's cosine similarity to the tag's (averaged) prompt
// embedding reaches Threshold.
type TagConfig struct {
	Tag       string   `mapstructure:"tag" json:"tag"`
	Prompts   []string `mapstructure:"prompts" json:"prompts"`
	Threshold float64  `mapstructure:"threshold" json:"threshold"`
}

// defaultThreshold is a starting guess for CLIP ViT-B/32 image-text cosine
// similarity (matches typically land around 0.22-0.30, non-matches around
// 0.15-0.20). It is UNCALIBRATED: tune it per tag with TestTagCalibration.
const defaultThreshold = 0.25

// DefaultTags is the initial tag set, used when gallery.ai.tags is not configured.
var DefaultTags = []TagConfig{
	{"person", []string{"a photo of a person", "a portrait of a person"}, defaultThreshold},
	{"group", []string{"a photo of a group of people"}, defaultThreshold},
	{"pet", []string{"a photo of a dog", "a photo of a cat"}, defaultThreshold},
	{"animal", []string{"a photo of an animal", "a photo of wildlife"}, defaultThreshold},
	{"building", []string{"a photo of a building", "a photo of architecture"}, defaultThreshold},
	{"city", []string{"a photo of a city", "a photo of a street in a city"}, defaultThreshold},
	{"nature", []string{"a photo of nature", "a photo of a forest", "a photo of a landscape"}, defaultThreshold},
	{"beach", []string{"a photo of a beach", "a photo of the sea shore"}, defaultThreshold},
	{"mountains", []string{"a photo of mountains", "a photo of a mountain landscape"}, defaultThreshold},
	{"food", []string{"a photo of food", "a photo of a meal on a plate"}, defaultThreshold},
	{"vehicle", []string{"a photo of a car", "a photo of a vehicle"}, defaultThreshold},
	{"document", []string{"a photo of a document", "a photo of printed text"}, defaultThreshold},
	{"screenshot", []string{"a screenshot of a computer screen", "a screenshot of a phone app"}, defaultThreshold},
	{"night", []string{"a photo taken at night", "a dark photo of a city at night"}, defaultThreshold},
}

// TagEmbedding is a tag with its L2-normalised text embedding.
type TagEmbedding struct {
	TagConfig
	vec []float32
}

// EmbedTags computes each tag's embedding: the mean of its prompts' CLIP text
// embeddings, L2-normalised.
func (m *MLClient) EmbedTags(ctx context.Context, tags []TagConfig) ([]TagEmbedding, error) {
	res := make([]TagEmbedding, 0, len(tags))
	for _, t := range tags {
		mean := make([]float64, 512)
		for _, p := range t.Prompts {
			v, err := m.EmbedText(ctx, p)
			if err != nil {
				return nil, fmt.Errorf("embed prompt %q: %w", p, err)
			}
			for i, f := range v {
				mean[i] += float64(f)
			}
		}
		vec := make([]float32, 512)
		norm := norm(mean)
		for i := range mean {
			vec[i] = float32(mean[i] / norm)
		}
		res = append(res, TagEmbedding{t, vec})
	}
	return res, nil
}

// Scores returns the cosine similarity of a photo embedding to every tag.
func Scores(tags []TagEmbedding, emb []float32) []float32 {
	e := make([]float64, len(emb))
	for i, f := range emb {
		e[i] = float64(f)
	}
	n := norm(e)
	res := make([]float32, len(tags))
	for i, t := range tags {
		var dot float64
		for j, f := range t.vec {
			dot += float64(f) * e[j]
		}
		res[i] = float32(dot / n)
	}
	return res
}

func norm(v []float64) float64 {
	var sum float64
	for _, f := range v {
		sum += f * f
	}
	return max(math.Sqrt(sum), 1e-12) // a zero vector scores 0 everywhere instead of NaN
}

// insertTags stores every tag whose score reaches its threshold.
func insertTags(ctx context.Context, tx pgx.Tx, providerID, path string, emb []float32, tags []TagEmbedding) error {
	for i, score := range Scores(tags, emb) {
		if float64(score) < tags[i].Threshold {
			continue
		}
		if _, err := tx.Exec(ctx, `INSERT INTO photo_tags (provider_id, path, tag, score) VALUES ($1, $2, $3, $4)`,
			providerID, path, tags[i].Tag, score); err != nil {
			return fmt.Errorf("insert tag: %w", err)
		}
	}
	return nil
}

// tagConfigHash identifies everything photo_tags is a function of (besides the
// stored embeddings): the normalised tag config and the CLIP model.
func (s *Service) tagConfigHash() string {
	tags := slices.Clone(s.cfg.Tags)
	for i := range tags {
		tags[i].Prompts = slices.Sorted(slices.Values(tags[i].Prompts))
	}
	slices.SortFunc(tags, func(a, b TagConfig) int { return strings.Compare(a.Tag, b.Tag) })
	b, _ := json.Marshal(struct {
		Model string
		Tags  []TagConfig
	}{s.cfg.ClipModel, tags})
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

const maxTagRetryDelay = 5 * time.Minute

// prepareTags computes the tag embeddings, retrying with backoff while the ML
// server is unreachable (store tags nothing until they are ready), then
// re-tags existing photos if the tag config changed.
func (s *Service) prepareTags(ctx context.Context) {
	delay := s.tagRetryDelay
	for {
		tags, err := s.ml.EmbedTags(ctx, s.cfg.Tags)
		if err == nil {
			s.tags.Store(&tags)
			break
		}
		if ctx.Err() != nil {
			return
		}
		s.log.Error("cannot compute tag embeddings; will retry", "error", err, "retryIn", delay)
		select {
		case <-ctx.Done():
			return
		case <-time.After(delay):
		}
		delay = min(delay*2, maxTagRetryDelay)
	}
	s.retag(ctx)
}

// retagBatch is how many photos the re-tag pass handles per transaction.
const retagBatch = 200

// retag recomputes photo_tags for all live photos from their stored embeddings
// (no ML image calls) unless tag_state says it is already current for this
// config. store() overwrites tag_state with a unique "pending:..." value when it
// had to skip tagging, so photos analysed before the tag embeddings were ready
// are caught here. The final write only succeeds if tag_state is still what the
// pass started from; otherwise a store marked something pending meanwhile and
// the pass runs again.
func (s *Service) retag(ctx context.Context) {
	hash := s.tagConfigHash()
	tags := *s.tags.Load()
	for {
		var stored string
		if err := s.pool.QueryRow(ctx, `SELECT config_hash FROM tag_state`).Scan(&stored); err != nil {
			s.log.Error("re-tag: read tag state failed", "error", err)
			return
		}
		if stored == hash {
			return
		}

		job := messaging.NewJob(s.nc, "gallery-ai.tagging", "AI tagging")
		// abort ends the pass's Job as failed, unless the service is just shutting down
		abort := func(err error) {
			if ctx.Err() == nil {
				job.Fail(err)
			}
			job.Close()
		}
		var total int64
		if err := s.pool.QueryRow(ctx, `
			SELECT count(*) FROM photos p JOIN photo_embeddings e ON e.provider_id = p.provider_id AND e.path = p.path
			WHERE NOT p.deleted`).Scan(&total); err != nil {
			s.log.Error("re-tag: count photos failed", "error", err)
			abort(err)
			return
		}
		job.Progress(0, total, fmt.Sprintf("0 of %d photos", total))

		var lastProvider, lastPath string
		done := 0
		for {
			n, err := s.retagBatch(ctx, tags, &lastProvider, &lastPath)
			if err != nil {
				if ctx.Err() == nil {
					s.log.Error("re-tag aborted", "error", err)
				}
				abort(err)
				return
			}
			if n == 0 {
				break
			}
			done += n
			job.Progress(int64(done), total, fmt.Sprintf("%d of %d photos", done, total))
		}
		// photos may have come or gone since the count; the pass is over, so done is the total
		job.Progress(int64(done), int64(done), fmt.Sprintf("%d of %d photos", done, done))
		job.Complete(fmt.Sprintf("%d photos tagged", done))
		job.Close()
		if s.beforeTagStateWrite != nil {
			s.beforeTagStateWrite()
		}
		res, err := s.pool.Exec(ctx, `UPDATE tag_state SET config_hash = $1 WHERE config_hash = $2`, hash, stored)
		if err != nil {
			s.log.Error("re-tag: record tag state failed", "error", err)
			return
		}
		if res.RowsAffected() == 1 {
			s.log.Info("re-tag finished", "photos", done)
			return
		}
		s.log.Info("tagging was skipped during re-tag; running it again")
	}
}

// retagBatch re-tags the next batch after (lastProvider, lastPath) and
// advances the cursor. The photos rows are locked, like in store, so a
// concurrent analysis of the same photo cannot be overwritten with stale tags.
func (s *Service) retagBatch(ctx context.Context, tags []TagEmbedding, lastProvider, lastPath *string) (int, error) {
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("begin: %w", err)
	}
	defer tx.Rollback(ctx)

	type photo struct {
		provider, path string
		emb            []float32
	}
	rows, err := tx.Query(ctx, `
		SELECT p.provider_id, p.path, e.embedding::text FROM photos p
		JOIN photo_embeddings e ON e.provider_id = p.provider_id AND e.path = p.path
		WHERE NOT p.deleted AND (p.provider_id, p.path) > ($1, $2)
		ORDER BY p.provider_id, p.path LIMIT $3 FOR UPDATE OF p`, *lastProvider, *lastPath, retagBatch)
	if err != nil {
		return 0, fmt.Errorf("query photos: %w", err)
	}
	batch, err := pgx.CollectRows(rows, func(r pgx.CollectableRow) (photo, error) {
		var p photo
		var emb string
		if err := r.Scan(&p.provider, &p.path, &emb); err != nil {
			return p, err
		}
		p.emb, err = parseVector(emb)
		return p, err
	})
	if err != nil {
		return 0, fmt.Errorf("query photos: %w", err)
	}

	for _, p := range batch {
		if _, err := tx.Exec(ctx, `DELETE FROM photo_tags WHERE provider_id = $1 AND path = $2`, p.provider, p.path); err != nil {
			return 0, fmt.Errorf("delete tags: %w", err)
		}
		if err := insertTags(ctx, tx, p.provider, p.path, p.emb, tags); err != nil {
			return 0, err
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("commit: %w", err)
	}
	if len(batch) > 0 {
		last := batch[len(batch)-1]
		*lastProvider, *lastPath = last.provider, last.path
	}
	return len(batch), nil
}
