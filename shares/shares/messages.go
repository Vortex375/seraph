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

package shares

// Code generated by avro/gen. DO NOT EDIT.

import (
	"github.com/hamba/avro/v2"
)

// ShareResolveRequest is a generated struct.
type ShareResolveRequest struct {
	ShareID string `avro:"shareId" bson:"shareId" json:"shareId"`
	Path    string `avro:"path" bson:"path" json:"path"`
}

var schemaShareResolveRequest = avro.MustParse(`{"name":"seraph.shares.ShareResolveRequest","type":"record","fields":[{"name":"shareId","type":"string"},{"name":"path","type":"string"}]}`)

// Schema returns the schema for ShareResolveRequest.
func (o *ShareResolveRequest) Schema() avro.Schema {
	return schemaShareResolveRequest
}

// Unmarshal decodes b into the receiver.
func (o *ShareResolveRequest) Unmarshal(b []byte) error {
	return avro.Unmarshal(o.Schema(), b, o)
}

// Marshal encodes the receiver.
func (o *ShareResolveRequest) Marshal() ([]byte, error) {
	return avro.Marshal(o.Schema(), o)
}

// ShareResolveResponse is a generated struct.
type ShareResolveResponse struct {
	Error      string `avro:"error" bson:"error" json:"error"`
	ProviderID string `avro:"providerId" bson:"providerId" json:"providerId"`
	Path       string `avro:"path" bson:"path" json:"path"`
}

var schemaShareResolveResponse = avro.MustParse(`{"name":"seraph.shares.ShareResolveResponse","type":"record","fields":[{"name":"error","type":"string"},{"name":"providerId","type":"string"},{"name":"path","type":"string"}]}`)

// Schema returns the schema for ShareResolveResponse.
func (o *ShareResolveResponse) Schema() avro.Schema {
	return schemaShareResolveResponse
}

// Unmarshal decodes b into the receiver.
func (o *ShareResolveResponse) Unmarshal(b []byte) error {
	return avro.Unmarshal(o.Schema(), b, o)
}

// Marshal encodes the receiver.
func (o *ShareResolveResponse) Marshal() ([]byte, error) {
	return avro.Marshal(o.Schema(), o)
}

// Share is a generated struct.
type Share struct {
	ShareID     string `avro:"shareId" bson:"shareId" json:"shareId"`
	Owner       string `avro:"owner" bson:"owner" json:"owner"`
	Title       string `avro:"title" bson:"title" json:"title"`
	Description string `avro:"description" bson:"description" json:"description"`
	ProviderID  string `avro:"providerId" bson:"providerId" json:"providerId"`
	Path        string `avro:"path" bson:"path" json:"path"`
	Recursive   bool   `avro:"recursive" bson:"recursive" json:"recursive"`
	IsDir       bool   `avro:"isDir" bson:"isDir" json:"isDir"`
}

var schemaShare = avro.MustParse(`{"name":"seraph.shares.Share","type":"record","fields":[{"name":"shareId","type":"string"},{"name":"owner","type":"string"},{"name":"title","type":"string"},{"name":"description","type":"string"},{"name":"providerId","type":"string"},{"name":"path","type":"string"},{"name":"recursive","type":"boolean"},{"name":"isDir","type":"boolean"}]}`)

// Schema returns the schema for Share.
func (o *Share) Schema() avro.Schema {
	return schemaShare
}

// Unmarshal decodes b into the receiver.
func (o *Share) Unmarshal(b []byte) error {
	return avro.Unmarshal(o.Schema(), b, o)
}

// Marshal encodes the receiver.
func (o *Share) Marshal() ([]byte, error) {
	return avro.Marshal(o.Schema(), o)
}

// ShareCrudRequest is a generated struct.
type ShareCrudRequest struct {
	Operation string `avro:"operation" bson:"operation" json:"operation"`
	Share     *Share `avro:"share" bson:"share" json:"share"`
}

var schemaShareCrudRequest = avro.MustParse(`{"name":"seraph.shares.ShareCrudRequest","type":"record","fields":[{"name":"operation","type":"string"},{"name":"share","type":["seraph.shares.Share","null"]}]}`)

// Schema returns the schema for ShareCrudRequest.
func (o *ShareCrudRequest) Schema() avro.Schema {
	return schemaShareCrudRequest
}

// Unmarshal decodes b into the receiver.
func (o *ShareCrudRequest) Unmarshal(b []byte) error {
	return avro.Unmarshal(o.Schema(), b, o)
}

// Marshal encodes the receiver.
func (o *ShareCrudRequest) Marshal() ([]byte, error) {
	return avro.Marshal(o.Schema(), o)
}

// ShareCrudResponse is a generated struct.
type ShareCrudResponse struct {
	Error string `avro:"error" bson:"error" json:"error"`
	Share *Share `avro:"share" bson:"share" json:"share"`
}

var schemaShareCrudResponse = avro.MustParse(`{"name":"seraph.shares.ShareCrudResponse","type":"record","fields":[{"name":"error","type":"string"},{"name":"share","type":["seraph.shares.Share","null"]}]}`)

// Schema returns the schema for ShareCrudResponse.
func (o *ShareCrudResponse) Schema() avro.Schema {
	return schemaShareCrudResponse
}

// Unmarshal decodes b into the receiver.
func (o *ShareCrudResponse) Unmarshal(b []byte) error {
	return avro.Unmarshal(o.Schema(), b, o)
}

// Marshal encodes the receiver.
func (o *ShareCrudResponse) Marshal() ([]byte, error) {
	return avro.Marshal(o.Schema(), o)
}