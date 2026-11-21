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

// Internal request/reply topics (JSON). Every request carries the caller's
// physical Prefixes and only rows under one of them are visible; every
// response has an Error that is empty on success. The gallery service fronts
// these with user-scoped topics.
const (
	SearchTopic       = "seraph.gallery.ai.search"
	StatusTopic       = "seraph.gallery.ai.status"
	PeopleTopic       = "seraph.gallery.ai.people"
	PersonRenameTopic = "seraph.gallery.ai.person.rename"
	PhotoTopic        = "seraph.gallery.ai.photo"
	FaceAssignTopic   = "seraph.gallery.ai.face.assign"
)

const (
	DefaultSearchLimit = 200
	MaxSearchLimit     = 1000
)

// Prefix is a physical folder: a photo is under it when it has the same provider and its
// path is the prefix or below it. Path "/" is the whole provider.
type Prefix struct {
	ProviderID string `json:"providerId"`
	Path       string `json:"path"`
}

type SearchRequest struct {
	Prefixes []Prefix `json:"prefixes"`
	Text     string   `json:"text,omitempty"`
	Tag      string   `json:"tag,omitempty"`
	PersonID string   `json:"personId,omitempty"`
	// Limit defaults to DefaultSearchLimit and is capped at MaxSearchLimit.
	Limit int `json:"limit"`
}

type SearchItem struct {
	ProviderID string `json:"providerId"`
	Path       string `json:"path"`
	// Score is 1 - cosine distance to the text embedding; 0 without text.
	Score float64 `json:"score"`
}

type SearchResponse struct {
	Error string       `json:"error"`
	Items []SearchItem `json:"items"`
}

type StatusRequest struct {
	Prefixes []Prefix `json:"prefixes"`
}

// StatusResponse counts live photos gallery-ai has received. Pending are those with neither an
// embedding nor an error; photos not yet delivered to gallery-ai are not counted.
type StatusResponse struct {
	Error    string `json:"error"`
	Analysed int    `json:"analysed"`
	Pending  int    `json:"pending"`
	Failed   int    `json:"failed"`
}

// Box is a normalised face bounding box.
type Box struct {
	X1 float32 `json:"x1"`
	Y1 float32 `json:"y1"`
	X2 float32 `json:"x2"`
	Y2 float32 `json:"y2"`
}

type Cover struct {
	ProviderID string `json:"providerId"`
	Path       string `json:"path"`
	Box        Box    `json:"box"`
}

type Person struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	PhotoCount int    `json:"photoCount"`
	Cover      Cover  `json:"cover"`
}

type PeopleRequest struct {
	Prefixes []Prefix `json:"prefixes"`
}

type PeopleResponse struct {
	Error  string   `json:"error"`
	People []Person `json:"people"`
}

type PersonRenameRequest struct {
	Prefixes []Prefix `json:"prefixes"`
	ID       string   `json:"id"`
	// Name may be empty, which makes the person unnamed.
	Name string `json:"name"`
}

type PersonResponse struct {
	Error  string  `json:"error"`
	Person *Person `json:"person"`
}

type PhotoRequest struct {
	Prefixes   []Prefix `json:"prefixes"`
	ProviderID string   `json:"providerId"`
	Path       string   `json:"path"`
}

type PhotoTag struct {
	Tag   string  `json:"tag"`
	Score float64 `json:"score"`
}

// PhotoFace omits personId/personName while the face is unassigned: clients read a
// missing personId as "no person".
type PhotoFace struct {
	ID         string `json:"id"`
	Box        Box    `json:"box"`
	PersonID   string `json:"personId,omitempty"`
	PersonName string `json:"personName,omitempty"`
	Manual     bool   `json:"manual"`
}

type PhotoResponse struct {
	// Error is a failed request ("not found" when the photo is not visible); AnalysisError is the
	// photo's recorded analysis failure.
	Error         string      `json:"error"`
	Analysed      bool        `json:"analysed"`
	AnalysisError string      `json:"analysisError"`
	Tags          []PhotoTag  `json:"tags"`
	Faces         []PhotoFace `json:"faces"`
}

// FaceAssignRequest sets exactly one of PersonID, NewPersonName and Unassign.
type FaceAssignRequest struct {
	Prefixes      []Prefix `json:"prefixes"`
	FaceID        string   `json:"faceId"`
	PersonID      string   `json:"personId,omitempty"`
	NewPersonName string   `json:"newPersonName,omitempty"`
	Unassign      bool     `json:"unassign,omitempty"`
}

type FaceResponse struct {
	Error string     `json:"error"`
	Face  *PhotoFace `json:"face"`
}
