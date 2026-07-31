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

package webdav

import (
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"path"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"golang.org/x/net/webdav"
)

// Staging files are named so that they are recognizable as ours, sort out of
// the way and are hidden on unix-like systems, in case they ever become
// visible to a user.
const (
	stagingPrefix = ".seraph-upload-"
	stagingSuffix = ".part"
)

// staging files older than this are considered orphaned and are removed by the sweeper
const stagingMaxAge = 24 * time.Hour

// a single directory is swept for orphaned staging files at most once per this interval
const sweepInterval = time.Hour

// budget for moving a finished upload into place or removing an aborted one
const finalizeTimeout = 30 * time.Second

// budget for one directory sweep
const sweepTimeout = 60 * time.Second

func stagingName() string {
	return stagingPrefix + uuid.NewString() + stagingSuffix
}

func isStagingName(name string) bool {
	return strings.HasPrefix(name, stagingPrefix) && strings.HasSuffix(name, stagingSuffix)
}

// key for the request-scoped state of an in-flight PUT
type putContextKey struct{}

// putRequest carries what is needed to tell a completed upload from an aborted
// one. It is installed by [withAtomicPut] and consumed by [atomicPutFs.OpenFile].
type putRequest struct {
	contentLength int64 // -1 when unknown, i.e. chunked transfer encoding
	body          *trackingBody
	staged        bool // whether a staging file was already opened for this request
}

func putRequestFrom(ctx context.Context) *putRequest {
	put, _ := ctx.Value(putContextKey{}).(*putRequest)
	return put
}

// trackingBody records whether the request body was consumed in full. net/http
// returns io.EOF only once the complete body - or, with chunked encoding, the
// terminating chunk - has arrived; a client that disappears mid-upload surfaces
// as a read error instead.
type trackingBody struct {
	io.ReadCloser

	read     int64
	complete bool
	err      error
}

func (b *trackingBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	b.read += int64(n)
	switch {
	case err == nil:
	case errors.Is(err, io.EOF):
		b.complete = true
	default:
		b.err = err
	}
	return n, err
}

// withAtomicPut marks PUT requests for staged handling by [atomicPutFs] and
// replaces the request body with one that reports whether it was received
// completely.
func withAtomicPut(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPut {
			next.ServeHTTP(w, r)
			return
		}

		body := &trackingBody{ReadCloser: r.Body}
		put := &putRequest{contentLength: r.ContentLength, body: body}

		r = r.WithContext(context.WithValue(r.Context(), putContextKey{}, put))
		r.Body = body

		next.ServeHTTP(w, r)
	})
}

// atomicPutFs makes WebDAV PUT atomic.
//
// golang.org/x/net/webdav opens the destination with O_CREATE|O_TRUNC and
// streams the request body straight into it, so an upload that is interrupted -
// by a dropped connection, an aborting client or a failing backend - destroys
// whatever was at that path before and leaves a partial file in its place,
// without any rollback.
//
// This decorator redirects such an open to a staging file next to the
// destination and renames it over the destination only once the request body
// has been received in full. Anything else deletes the staging file, so the
// destination either still holds its previous content or does not exist.
type atomicPutFs struct {
	webdav.FileSystem

	log     *slog.Logger
	sweeper *stagingSweeper
}

var _ webdav.FileSystem = &atomicPutFs{}

func (f *atomicPutFs) OpenFile(ctx context.Context, name string, flag int, perm os.FileMode) (webdav.File, error) {
	put := putRequestFrom(ctx)
	if put == nil || put.staged || flag&os.O_CREATE == 0 || flag&os.O_TRUNC == 0 {
		file, err := f.FileSystem.OpenFile(ctx, name, flag, perm)
		if err != nil {
			return nil, err
		}
		return &hidingFile{File: file}, nil
	}
	// handlePut() opens the destination exactly once, everything after that is
	// not the upload we staged for
	put.staged = true

	staging := path.Join(path.Dir(name), stagingName())
	file, err := f.FileSystem.OpenFile(ctx, staging, flag, perm)
	if err != nil {
		return nil, err
	}
	f.log.Debug("staging upload", "target", name, "staging", staging)

	return &stagedFile{
		File:    file,
		ctx:     ctx,
		fs:      f.FileSystem,
		log:     f.log,
		sweeper: f.sweeper,
		target:  name,
		staging: staging,
		put:     put,
	}, nil
}

// stagedFile buffers a PUT into a staging file which is published - or thrown
// away - when the handler closes it.
type stagedFile struct {
	webdav.File

	ctx     context.Context
	fs      webdav.FileSystem
	log     *slog.Logger
	sweeper *stagingSweeper
	target  string
	staging string
	put     *putRequest
	written int64
	closed  bool
}

func (f *stagedFile) Write(p []byte) (int, error) {
	n, err := f.File.Write(p)
	f.written += int64(n)
	return n, err
}

func (f *stagedFile) Stat() (fs.FileInfo, error) {
	info, err := f.File.Stat()
	if err != nil {
		return nil, err
	}
	// handlePut() derives the ETag from this, so report the destination
	return &renamedFileInfo{FileInfo: info, name: path.Base(f.target)}, nil
}

// Close publishes the upload: the staging file replaces the destination if -
// and only if - the request body arrived in full, and is deleted otherwise.
func (f *stagedFile) Close() error {
	if f.closed {
		return nil
	}
	f.closed = true

	closeErr := f.File.Close()

	// the request context is already cancelled when the client went away, so
	// finishing up needs a context of its own
	ctx, cancel := context.WithTimeout(context.WithoutCancel(f.ctx), finalizeTimeout)
	defer cancel()

	if err := f.aborted(closeErr); err != nil {
		f.discard(ctx, err)
		return err
	}
	if err := f.commit(ctx); err != nil {
		f.discard(ctx, err)
		return err
	}

	f.log.Debug("published upload", "target", f.target, "size", f.written)
	f.sweeper.schedule(f.ctx, f.fs, path.Dir(f.staging))

	return nil
}

// aborted reports why the upload must not be published, or nil if the
// destination may be replaced.
func (f *stagedFile) aborted(closeErr error) error {
	switch {
	case closeErr != nil:
		return closeErr
	case f.put.body.err != nil:
		return fmt.Errorf("upload of %s aborted: %w", f.target, f.put.body.err)
	case !f.put.body.complete:
		return fmt.Errorf("upload of %s aborted before the request body was read completely", f.target)
	case f.put.contentLength >= 0 && f.written != f.put.contentLength:
		return fmt.Errorf("upload of %s is incomplete: stored %d of %d bytes", f.target, f.written, f.put.contentLength)
	}
	return nil
}

// commit moves the completed staging file to its destination. A plain rename
// replaces an existing destination on a local filesystem, but SMB refuses to
// (go-smb2 sends FileRenameInformation with ReplaceIfExists unset), so on
// failure the previous file is moved aside and only removed once the new one is
// in place.
func (f *stagedFile) commit(ctx context.Context) error {
	renameErr := f.fs.Rename(ctx, f.staging, f.target)
	if renameErr == nil {
		return nil
	}

	// the backup carries a staging name of its own, so the sweeper collects it
	// should anything below fail to clean it up
	backup := path.Join(path.Dir(f.target), stagingName())
	if err := f.fs.Rename(ctx, f.target, backup); err != nil {
		// nothing to move aside - the destination is missing or immovable, so
		// the original failure is the one that matters
		return fmt.Errorf("unable to move %s to %s: %w", f.staging, f.target, renameErr)
	}

	if err := f.fs.Rename(ctx, f.staging, f.target); err != nil {
		if restoreErr := f.fs.Rename(ctx, backup, f.target); restoreErr != nil {
			f.log.Error("unable to restore previous file after failed upload", "target", f.target, "backup", backup, "error", restoreErr)
		}
		return fmt.Errorf("unable to move %s to %s: %w", f.staging, f.target, err)
	}

	if err := f.fs.RemoveAll(ctx, backup); err != nil {
		f.log.Warn("unable to remove replaced file", "path", backup, "error", err)
	}
	return nil
}

func (f *stagedFile) discard(ctx context.Context, cause error) {
	f.log.Warn("discarding incomplete upload", "target", f.target, "staging", f.staging, "error", cause)
	if err := f.fs.RemoveAll(ctx, f.staging); err != nil {
		f.log.Error("unable to remove staging file of incomplete upload", "staging", f.staging, "error", err)
	}
}

// hidingFile keeps in-flight uploads out of directory listings, so that clients
// neither try to synchronize nor stumble over half-written files.
type hidingFile struct {
	webdav.File
}

func (f *hidingFile) Readdir(count int) ([]fs.FileInfo, error) {
	infos, err := f.File.Readdir(count)
	// a positive count promises "at most n entries, io.EOF when there are no
	// more" - filtering would break that contract, and every caller in Seraph
	// reads whole directories anyway
	if err != nil || count > 0 {
		return infos, err
	}

	filtered := infos[:0]
	for _, info := range infos {
		if !isStagingName(info.Name()) {
			filtered = append(filtered, info)
		}
	}
	return filtered, nil
}

type renamedFileInfo struct {
	fs.FileInfo

	name string
}

func (i *renamedFileInfo) Name() string {
	return i.name
}

// stagingSweeper removes staging files that were left behind when the gateway
// died mid-upload. Directories are swept opportunistically after an upload was
// published, at most once per [sweepInterval], which keeps the cost
// proportional to upload traffic rather than to the size of the tree - and
// sweeps exactly those directories where orphans can appear.
type stagingSweeper struct {
	log *slog.Logger

	lastSweep sync.Map // directory -> time.Time
}

func newStagingSweeper(log *slog.Logger) *stagingSweeper {
	return &stagingSweeper{log: log}
}

// due reports whether dir may be swept again, and claims the slot if so.
func (s *stagingSweeper) due(dir string) bool {
	now := time.Now()
	if last, ok := s.lastSweep.Load(dir); ok && now.Sub(last.(time.Time)) < sweepInterval {
		return false
	}
	s.lastSweep.Store(dir, now)

	// an entry older than sweepInterval no longer suppresses anything, so
	// dropping it keeps the map from growing forever on a server that receives
	// uploads into ever new directories
	s.lastSweep.Range(func(dir, last any) bool {
		if now.Sub(last.(time.Time)) >= sweepInterval {
			s.lastSweep.Delete(dir)
		}
		return true
	})

	return true
}

// schedule sweeps dir in the background unless it was swept recently.
func (s *stagingSweeper) schedule(ctx context.Context, fsys webdav.FileSystem, dir string) {
	if s == nil || !s.due(dir) {
		return
	}

	// the request is done as far as the client is concerned, so don't hold up
	// its response and don't let its cancellation cut the sweep short
	sweepCtx := context.WithoutCancel(ctx)
	go func() {
		ctx, cancel := context.WithTimeout(sweepCtx, sweepTimeout)
		defer cancel()
		s.sweep(ctx, fsys, dir)
	}()
}

func (s *stagingSweeper) sweep(ctx context.Context, fsys webdav.FileSystem, dir string) {
	file, err := fsys.OpenFile(ctx, dir, os.O_RDONLY, 0)
	if err != nil {
		s.log.Debug("unable to open directory for staging sweep", "dir", dir, "error", err)
		return
	}
	infos, err := file.Readdir(-1)
	file.Close()
	if err != nil {
		s.log.Debug("unable to list directory for staging sweep", "dir", dir, "error", err)
		return
	}

	now := time.Now()
	for _, info := range infos {
		if !isStagingName(info.Name()) || now.Sub(info.ModTime()) < stagingMaxAge {
			continue
		}
		orphan := path.Join(dir, info.Name())
		if err := fsys.RemoveAll(ctx, orphan); err != nil {
			s.log.Warn("unable to remove orphaned staging file", "path", orphan, "error", err)
		} else {
			s.log.Info("removed orphaned staging file", "path", orphan)
		}
	}
}
