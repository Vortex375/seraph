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
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"strings"
	"time"
)

// MLClient talks to Immich's machine-learning container (POST /predict).
type MLClient struct {
	url          string
	clipModel    string
	faceModel    string
	faceMinScore float64
	http         *http.Client
}

func NewMLClient(c Config) *MLClient {
	return &MLClient{
		url:          strings.TrimRight(c.MLURL, "/"),
		clipModel:    c.ClipModel,
		faceModel:    c.FaceModel,
		faceMinScore: c.FaceMinScore,
		// the first request after a cold start downloads the models
		http: &http.Client{Timeout: 5 * time.Minute},
	}
}

// Face is one detected face; the box is normalised to 0..1.
type Face struct {
	X1, Y1, X2, Y2 float32
	Score          float32
	Embedding      []float32
}

type Analysis struct {
	Embedding []float32
	Faces     []Face
}

type mlFace struct {
	BoundingBox struct {
		X1 float64 `json:"x1"`
		Y1 float64 `json:"y1"`
		X2 float64 `json:"x2"`
		Y2 float64 `json:"y2"`
	} `json:"boundingBox"`
	Embedding string  `json:"embedding"`
	Score     float64 `json:"score"`
}

// Analyse returns the CLIP image embedding and the faces of one image.
func (m *MLClient) Analyse(ctx context.Context, image []byte) (*Analysis, error) {
	entries := map[string]any{
		"clip": map[string]any{"visual": map[string]any{"modelName": m.clipModel}},
		"facial-recognition": map[string]any{
			"detection":   map[string]any{"modelName": m.faceModel, "options": map[string]any{"minScore": m.faceMinScore}},
			"recognition": map[string]any{"modelName": m.faceModel},
		},
	}
	body, err := m.predict(ctx, entries, "image", image)
	if err != nil {
		return nil, err
	}

	var resp struct {
		Clip   string   `json:"clip"`
		Faces  []mlFace `json:"facial-recognition"`
		ImageW float64  `json:"imageWidth"`
		ImageH float64  `json:"imageHeight"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, permanent(fmt.Errorf("decode ml response: %w", err))
	}

	res := &Analysis{}
	if res.Embedding, err = parseVector(resp.Clip); err != nil {
		return nil, permanent(fmt.Errorf("ml clip embedding: %w", err))
	}
	if len(resp.Faces) > 0 && (resp.ImageW <= 0 || resp.ImageH <= 0) {
		return nil, permanent(fmt.Errorf("ml response has faces but no image size"))
	}
	for _, f := range resp.Faces {
		emb, err := parseVector(f.Embedding)
		if err != nil {
			return nil, permanent(fmt.Errorf("ml face embedding: %w", err))
		}
		b := f.BoundingBox
		res.Faces = append(res.Faces, Face{
			X1: clamp01(b.X1 / resp.ImageW), Y1: clamp01(b.Y1 / resp.ImageH),
			X2: clamp01(b.X2 / resp.ImageW), Y2: clamp01(b.Y2 / resp.ImageH),
			Score: float32(f.Score), Embedding: emb,
		})
	}
	return res, nil
}

// EmbedText returns the CLIP text embedding of a query or tag prompt.
func (m *MLClient) EmbedText(ctx context.Context, text string) ([]float32, error) {
	entries := map[string]any{"clip": map[string]any{"textual": map[string]any{"modelName": m.clipModel}}}
	body, err := m.predict(ctx, entries, "text", []byte(text))
	if err != nil {
		return nil, err
	}
	var resp struct {
		Clip string `json:"clip"`
	}
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, permanent(fmt.Errorf("decode ml response: %w", err))
	}
	v, err := parseVector(resp.Clip)
	if err != nil {
		return nil, permanent(fmt.Errorf("ml clip embedding: %w", err))
	}
	return v, nil
}

// predict posts one multipart request. 4xx is a permanent error; unreachable
// and 5xx are transient.
func (m *MLClient) predict(ctx context.Context, entries any, field string, payload []byte) ([]byte, error) {
	entriesJSON, err := json.Marshal(entries)
	if err != nil {
		return nil, err
	}

	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	if err := mw.WriteField("entries", string(entriesJSON)); err != nil {
		return nil, err
	}
	if field == "image" {
		part, err := mw.CreateFormFile("image", "image.jpg")
		if err != nil {
			return nil, err
		}
		part.Write(payload)
	} else if err := mw.WriteField(field, string(payload)); err != nil {
		return nil, err
	}
	if err := mw.Close(); err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, m.url+"/predict", &buf)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())

	resp, err := m.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("ml request: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("ml response: %w", err)
	}

	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return body, nil
	case resp.StatusCode >= 400 && resp.StatusCode < 500:
		return nil, permanent(fmt.Errorf("ml server rejected request: %s: %s", resp.Status, truncate(body)))
	default:
		return nil, fmt.Errorf("ml server error: %s: %s", resp.Status, truncate(body))
	}
}

func parseVector(s string) ([]float32, error) {
	var v []float32
	if err := json.Unmarshal([]byte(s), &v); err != nil {
		return nil, err
	}
	if len(v) != 512 {
		return nil, fmt.Errorf("expected 512 dimensions, got %d", len(v))
	}
	return v, nil
}

// vectorLiteral renders a pgvector text literal, to be cast with ::vector.
func vectorLiteral(v []float32) string {
	var sb strings.Builder
	sb.WriteByte('[')
	for i, f := range v {
		if i > 0 {
			sb.WriteByte(',')
		}
		fmt.Fprintf(&sb, "%g", f)
	}
	sb.WriteByte(']')
	return sb.String()
}

func clamp01(f float64) float32 {
	return float32(min(max(f, 0), 1))
}

func truncate(b []byte) string {
	if len(b) > 200 {
		b = b[:200]
	}
	return string(b)
}
