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
	"errors"
	"fmt"
	"time"

	"github.com/spf13/viper"
)

// Config is gallery-ai's settings. Keys live under "gallery.ai." so the
// environment variable names come out as SERAPH_GALLERY_AI_*.
type Config struct {
	DBURL            string
	MLURL            string
	ClipModel        string
	FaceModel        string
	FaceMinScore     float64
	MaxDistance      float64       // max cosine distance for two faces to be the same person
	MinFaces         int           // matches (itself included) a face needs to start a new person
	DeferredInterval time.Duration // how often never-clustered and deferred faces are reprocessed
	MaxAckPending    int
	SearchMinScore   float64 // text search drops photos below this cosine similarity
	Tags             []TagConfig
}

func NewConfig(v *viper.Viper) (Config, error) {
	v.SetDefault("gallery.ai.ml.url", "http://localhost:3003")
	v.SetDefault("gallery.ai.clip.model", "ViT-B-32__openai")
	v.SetDefault("gallery.ai.face.model", "buffalo_l")
	v.SetDefault("gallery.ai.face.minScore", 0.7)
	v.SetDefault("gallery.ai.face.maxDistance", 0.5)
	v.SetDefault("gallery.ai.face.minFaces", 3)
	v.SetDefault("gallery.ai.face.deferredInterval", 5*time.Minute)
	v.SetDefault("gallery.ai.maxAckPending", 2)
	// ponytail: a starting guess for CLIP ViT-B/32 bare-query scores, like defaultThreshold for tags; tune per model
	v.SetDefault("gallery.ai.search.minScore", 0.23)

	// gallery.ai.tags replaces the whole default list when set (config file; list of {tag, prompts, threshold})
	tags := DefaultTags
	if v.IsSet("gallery.ai.tags") {
		tags = nil
		if err := v.UnmarshalKey("gallery.ai.tags", &tags); err != nil {
			return Config{}, fmt.Errorf("read gallery.ai.tags: %w", err)
		}
	}
	for _, t := range tags {
		if t.Tag == "" || len(t.Prompts) == 0 {
			return Config{}, errors.New("gallery.ai.tags: every tag needs a name and at least one prompt")
		}
	}

	return Config{
		DBURL:            v.GetString("gallery.ai.db.url"),
		MLURL:            v.GetString("gallery.ai.ml.url"),
		ClipModel:        v.GetString("gallery.ai.clip.model"),
		FaceModel:        v.GetString("gallery.ai.face.model"),
		FaceMinScore:     v.GetFloat64("gallery.ai.face.minScore"),
		MaxDistance:      v.GetFloat64("gallery.ai.face.maxDistance"),
		MinFaces:         v.GetInt("gallery.ai.face.minFaces"),
		DeferredInterval: v.GetDuration("gallery.ai.face.deferredInterval"),
		MaxAckPending:    v.GetInt("gallery.ai.maxAckPending"),
		SearchMinScore:   v.GetFloat64("gallery.ai.search.minScore"),
		Tags:             tags,
	}, nil
}
