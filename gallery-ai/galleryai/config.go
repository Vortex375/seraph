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

import "github.com/spf13/viper"

// Config is gallery-ai's settings. Keys live under "gallery.ai." so the
// environment variable names come out as SERAPH_GALLERY_AI_*.
type Config struct {
	DBURL         string
	MLURL         string
	ClipModel     string
	FaceModel     string
	FaceMinScore  float64
	MaxAckPending int
}

func NewConfig(v *viper.Viper) Config {
	v.SetDefault("gallery.ai.ml.url", "http://localhost:3003")
	v.SetDefault("gallery.ai.clip.model", "ViT-B-32__openai")
	v.SetDefault("gallery.ai.face.model", "buffalo_l")
	v.SetDefault("gallery.ai.face.minScore", 0.7)
	v.SetDefault("gallery.ai.maxAckPending", 2)

	return Config{
		DBURL:         v.GetString("gallery.ai.db.url"),
		MLURL:         v.GetString("gallery.ai.ml.url"),
		ClipModel:     v.GetString("gallery.ai.clip.model"),
		FaceModel:     v.GetString("gallery.ai.face.model"),
		FaceMinScore:  v.GetFloat64("gallery.ai.face.minScore"),
		MaxAckPending: v.GetInt("gallery.ai.maxAckPending"),
	}
}
