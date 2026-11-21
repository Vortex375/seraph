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
	"io"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"
	"umbasa.net/seraph/gallery-ai/galleryai"
)

// mlImage is the Immich machine-learning image gallery-ai is validated
// against; keep it in sync with the docker-compose files.
const mlImage = "ghcr.io/immich-app/immich-machine-learning:v3.4.2"

// TestMLContract runs the real pinned ML image (opt-in: the image is large and
// the models download on first use). Run it when upgrading mlImage.
func TestMLContract(t *testing.T) {
	if os.Getenv("SERAPH_ML_CONTRACT") != "1" {
		t.Skip("set SERAPH_ML_CONTRACT=1 to run the ML container contract test")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()

	c, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: testcontainers.ContainerRequest{
			Image:        mlImage,
			ExposedPorts: []string{"3003/tcp"},
			WaitingFor: wait.ForHTTP("/ping").WithPort("3003/tcp").
				WithResponseMatcher(func(body io.Reader) bool {
					b, _ := io.ReadAll(body)
					return string(b) == "pong"
				}).WithStartupTimeout(10 * time.Minute),
		},
		Started: true,
	})
	require.NoError(t, err)
	t.Cleanup(func() { testcontainers.TerminateContainer(c) })
	endpoint, err := c.PortEndpoint(ctx, "3003/tcp", "http")
	require.NoError(t, err)

	cfg := galleryai.Config{MLURL: endpoint, ClipModel: "ViT-B-32__openai", FaceModel: "buffalo_l", FaceMinScore: 0.7}
	ml := galleryai.NewMLClient(cfg)

	jpeg, err := os.ReadFile("../../gallery/gallery/testdata/PXL_20240308_190141760.jpg")
	require.NoError(t, err)

	// the first calls download the models, which can take minutes
	a, err := ml.Analyse(ctx, jpeg)
	require.NoError(t, err)
	assert.Len(t, a.Embedding, 512)
	for _, f := range a.Faces { // the sample may contain no faces; whatever is returned must parse
		assert.Len(t, f.Embedding, 512)
		assert.True(t, f.X1 >= 0 && f.X2 <= 1 && f.X1 <= f.X2 && f.Y1 >= 0 && f.Y2 <= 1 && f.Y1 <= f.Y2)
	}
	t.Logf("faces found: %d", len(a.Faces))

	txt, err := ml.EmbedText(ctx, "a photo of a dog")
	require.NoError(t, err)
	assert.Len(t, txt, 512)

}
