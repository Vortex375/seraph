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

package galleryai_test

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/spf13/viper"
	"github.com/stretchr/testify/require"
	"umbasa.net/seraph/gallery-ai/galleryai"
)

// TestTagCalibration prints the per-tag cosine score of every image in
// SERAPH_TAG_CALIBRATE_DIR, using the real ML container at
// SERAPH_GALLERY_AI_ML_URL (default http://localhost:3003), so thresholds can
// be picked by comparing scores with what is actually in the photos. Opt-in.
func TestTagCalibration(t *testing.T) {
	dir := os.Getenv("SERAPH_TAG_CALIBRATE_DIR")
	if dir == "" {
		t.Skip("set SERAPH_TAG_CALIBRATE_DIR to a directory of images to print tag scores")
	}
	mlURL := os.Getenv("SERAPH_GALLERY_AI_ML_URL")
	if mlURL == "" {
		mlURL = "http://localhost:3003"
	}
	cfg, err := galleryai.NewConfig(viper.New())
	require.NoError(t, err)
	cfg.MLURL = mlURL
	ml := galleryai.NewMLClient(cfg)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	tags, err := ml.EmbedTags(ctx, cfg.Tags)
	require.NoError(t, err)

	files, err := filepath.Glob(filepath.Join(dir, "*"))
	require.NoError(t, err)

	var sb strings.Builder
	sb.WriteString("\n" + fmt.Sprintf("%-30s", "image"))
	for _, tag := range tags {
		sb.WriteString(fmt.Sprintf(" %10s", tag.Tag))
	}
	sb.WriteString("\n")
	for _, f := range files {
		img, err := os.ReadFile(f)
		if err != nil || len(img) == 0 {
			continue // directory or unreadable
		}
		a, err := ml.Analyse(ctx, img)
		if err != nil {
			sb.WriteString(fmt.Sprintf("%-30s %v\n", filepath.Base(f), err))
			continue
		}
		sb.WriteString(fmt.Sprintf("%-30.30s", filepath.Base(f)))
		for _, s := range galleryai.Scores(tags, a.Embedding) {
			sb.WriteString(fmt.Sprintf(" %10.3f", s))
		}
		sb.WriteString("\n")
	}
	t.Log(sb.String())
}
