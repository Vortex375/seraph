// Copyright © 2026 Benjamin Schmitz

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

// Package tagreader reads tags and pictures with TagLib (cgo) and answers the
// audiometadata protocol. Only the service binary imports it.
package tagreader

import (
	"context"
	"errors"
	"io/fs"
	"os"

	"github.com/nats-io/nats.go"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/audio-metadata/audiometadata"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/taglib"
)

// Opener opens a file of a File Provider; tests pass a local directory.
type Opener func(ctx context.Context, providerId string, path string) (webdav.File, error)

// ProviderOpener opens files through the File Provider client. A missing
// file is reported up front (fs.ErrNotExist): the client opens lazily, so
// without the Stat it would only surface as a failing read inside TagLib.
func ProviderOpener(nc *nats.Conn, logger *logging.Logger) Opener {
	return func(ctx context.Context, providerId string, path string) (webdav.File, error) {
		client := fileprovider.NewFileProviderClient(providerId, nc, logger)
		info, err := client.Stat(ctx, path)
		if err != nil {
			client.Close()
			return nil, err
		}
		if info.IsDir() {
			client.Close()
			return nil, errNotAFile
		}
		file, err := client.OpenFile(ctx, path, os.O_RDONLY, 0)
		if err != nil {
			client.Close()
			return nil, err
		}
		return &clientFile{File: file, client: client}, nil
	}
}

// clientFile closes its File Provider client with the file.
type clientFile struct {
	webdav.File
	client fileprovider.Client
}

func (f *clientFile) Close() error {
	err := f.File.Close()
	f.client.Close()
	return err
}

var errNotAFile = errors.New("not a file")

// Reader reads tags and pictures of files that open opens.
type Reader struct {
	open Opener
}

func NewReader(open Opener) *Reader {
	return &Reader{open: open}
}

// withFileRef opens path, parses it with TagLib (fast audio properties) and
// calls read with the FileRef; everything is freed afterwards. A failure is
// returned as an *audiometadata.Error.
func (r *Reader) withFileRef(ctx context.Context, providerId string, path string, read func(ref taglib.FileRef)) error {
	file, err := r.open(ctx, providerId, path)
	if err != nil {
		switch {
		case errors.Is(err, fs.ErrNotExist):
			return &audiometadata.Error{Class: audiometadata.ErrorClassNotFound, Message: "file not found"}
		case errors.Is(err, errNotAFile):
			return &audiometadata.Error{Class: audiometadata.ErrorClassUnsupported, Message: "not a file"}
		default:
			return &audiometadata.Error{Class: audiometadata.ErrorClassUnreadable, Message: "error opening file: " + err.Error()}
		}
	}
	stream := taglib.NewWebdavFileStream(path, file) // closes file on Delete
	defer stream.Delete()
	ref := taglib.NewFileRef(stream, true, taglib.AudioPropertiesFast)
	defer taglib.DeleteFileRef(ref) // before the stream: ref reads from it

	if ref.IsNull() {
		return &audiometadata.Error{Class: audiometadata.ErrorClassUnsupported, Message: "not a supported audio file"}
	}
	read(ref)
	return nil
}

// Tags reads path's tags.
func (r *Reader) Tags(ctx context.Context, providerId string, path string) audiometadata.TagsResponse {
	var resp audiometadata.TagsResponse
	err := r.withFileRef(ctx, providerId, path, func(ref taglib.FileRef) {
		tags := taglib.ReadTags(ref)
		resp = audiometadata.TagsResponse{
			Title:       tags.Title,
			Artist:      tags.Artist,
			Album:       tags.Album,
			AlbumArtist: tags.AlbumArtist,
			Genre:       tags.Genre,
			Year:        tags.Year,
			TrackNumber: tags.TrackNumber,
			DiscNumber:  tags.DiscNumber,
			DurationMs:  tags.DurationMs,
			HasPicture:  ref.PictureCount() > 0,
		}
	})
	var e *audiometadata.Error
	if errors.As(err, &e) {
		return audiometadata.TagsResponse{Error: e.Message, ErrorClass: e.Class}
	}
	return resp
}

// Picture returns length bytes (at most audiometadata.MaxPictureChunk) at
// offset of path's cover: the front cover, else the first picture.
//
// ponytail: every chunk re-reads the file - fine while the thumbnailer
// caches the result; add a short-lived per-path cache if covers show up hot.
func (r *Reader) Picture(ctx context.Context, providerId string, path string, offset int64, length int) audiometadata.PictureResponse {
	var resp audiometadata.PictureResponse
	err := r.withFileRef(ctx, providerId, path, func(ref taglib.FileRef) {
		cover, ok := frontCover(taglib.Pictures(ref))
		if !ok {
			resp = audiometadata.PictureResponse{Error: "no embedded picture", ErrorClass: audiometadata.ErrorClassNoPicture}
			return
		}
		resp = audiometadata.PictureResponse{
			MimeType:  cover.MimeType,
			TotalSize: int64(len(cover.Data)),
			Data:      chunk(cover.Data, offset, length),
		}
	})
	var e *audiometadata.Error
	if errors.As(err, &e) {
		return audiometadata.PictureResponse{Error: e.Message, ErrorClass: e.Class}
	}
	return resp
}

func frontCover(pictures []taglib.Picture) (taglib.Picture, bool) {
	for _, p := range pictures {
		if p.PictureType == "Front Cover" {
			return p, true
		}
	}
	if len(pictures) > 0 {
		return pictures[0], true
	}
	return taglib.Picture{}, false
}

func chunk(data []byte, offset int64, length int) []byte {
	length = min(length, audiometadata.MaxPictureChunk)
	if offset < 0 || offset >= int64(len(data)) || length <= 0 {
		return []byte{}
	}
	return data[offset:min(offset+int64(length), int64(len(data)))]
}
