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
	"bufio"
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
	"umbasa.net/seraph/file-provider/fileprovider"
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

	// Ensure the destination's parent directory exists before opening the
	// staging file. The fileprovider.Client's OpenFile is lazy (it defers the
	// real open to the first Read/Write), so an OpenFile against a path whose
	// parent collection is missing does NOT fail here - it fails later, inside
	// io.Copy, where golang.org/x/net/webdav's handlePut maps a copy error to
	// 405 Method Not Allowed rather than the 409 Conflict it returns when
	// OpenFile itself fails with ENOENT. That 405 is indistinguishable, to a
	// WebDAV client, from "this resource cannot be written at all", so
	// webdav_client's mkdirAll (which only walks segments on a 409) treats it
	// as "the directory exists" and the upload fails on every retry - the
	// symptom every background backup upload showed.
	//
	// Creating the parent here makes the staging OpenFile's eventual Write-time
	// open succeed regardless of whether the client ran mkdirAll first, and
	// mirrors what webdav_client's own wdWriteWithBytes does client-side - so
	// the server is robust to clients that don't, or that bail out of
	// mkdirAll early on an unexpected status.
	if dir := path.Dir(name); dir != "" && dir != "/" && dir != "." {
		if err := f.FileSystem.Mkdir(ctx, dir, 0777); err != nil && !errors.Is(err, fs.ErrExist) {
			// A missing intermediate parent surfaces as "does not exist" at the
			// deepest missing level; golang.org/x/net/webdav's Mkdir has no
			// recursive form, so walk up the missing chain from the leaf,
			// creating each level. This keeps the staging open self-sufficient
			// rather than depending on a client-side mkdirAll whose 405-vs-409
			// status mapping is exactly what failed on the phone.
			if err := mkdirAll(ctx, f.FileSystem, dir); err != nil {
				return nil, err
			}
		}
	}

	file, err := f.FileSystem.OpenFile(ctx, staging, flag, perm)
	if err != nil {
		return nil, err
	}
	f.log.Debug("staging upload", "target", name, "staging", staging)

	sf := &stagedFile{
		File:    file,
		ctx:     ctx,
		fs:      f.FileSystem,
		log:     f.log,
		sweeper: f.sweeper,
		target:  name,
		staging: staging,
		put:     put,
	}
	// golang.org/x/net/webdav's PUT handler does io.Copy(f, r.Body), which -
	// absent an io.ReaderFrom on f or an io.WriterTo on the body - reads and
	// writes in 32KB chunks. Each Write against the file provider is one NATS
	// request/reply capped at fileprovider.MaxPayload (768KB), so an unwrapped
	// destination turns one upload into dozens of avoidable round trips.
	// Buffering here batches writes up to MaxPayload before they ever reach the
	// client, independent of how small a single io.Copy chunk is.
	sf.buf = bufio.NewWriterSize(writerFunc(sf.writeThrough), fileprovider.MaxPayload)

	return sf, nil
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
	buf     *bufio.Writer
	written int64
	closed  bool
}

// writerFunc adapts a plain write method to io.Writer so it can sit behind
// bufio.Writer.
type writerFunc func(p []byte) (int, error)

func (w writerFunc) Write(p []byte) (int, error) {
	return w(p)
}

// writeThrough is what the buffer flushes into: the staging file itself.
func (f *stagedFile) writeThrough(p []byte) (int, error) {
	n, err := f.File.Write(p)
	f.written += int64(n)
	return n, err
}

// Write buffers into an internal buffer sized to the file provider's maximum
// payload, so bytes accumulate here rather than crossing to the provider at
// whatever chunk size the caller's io.Copy happens to use.
func (f *stagedFile) Write(p []byte) (int, error) {
	return f.buf.Write(p)
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

	// flush whatever is still buffered before the staging file is closed, or a
	// successful-looking upload could lose its last, incomplete buffer's worth
	// of bytes
	flushErr := f.buf.Flush()
	closeErr := f.File.Close()
	if flushErr != nil && closeErr == nil {
		closeErr = flushErr
	}

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

// mkdirAll creates the directory at name and any missing intermediate parent
// directories, like os.MkdirAll but over a webdav.FileSystem. The
// golang.org/x/net/webdav FileSystem interface has no recursive Mkdir, so this
// walks from the leaf upward, creating each level and treating "already
// exists" (fs.ErrExist) as success - the same semantics webdav_client's own
// client-side mkdirAll relies on, applied server-side so the staging OpenFile
// is self-sufficient regardless of whether the client ran mkdirAll.
//
// Used by [atomicPutFs.OpenFile] to guarantee the destination's parent
// collection exists before a staging file is opened in it, which is what
// makes a PUT to a path whose intermediate dirs do not exist yet succeed
// (rather than surfacing a Write-time ENOENT as a 405 from handlePut).
func mkdirAll(ctx context.Context, vfs webdav.FileSystem, name string) error {
	// Build the chain of missing ancestors bottom-up. Stat first so the
	// common case (everything exists) costs a single round-trip; only on a
	// missing ancestor does the walk begin.
	_, err := vfs.Stat(ctx, name)
	if err == nil {
		return nil
	}
	if !errors.Is(err, fs.ErrNotExist) {
		return err
	}

	// Collect the missing segments from the leaf up to (but not including)
	// the first existing ancestor.
	var missing []string
	dir := name
	for dir != "" && dir != "/" && dir != "." {
		if err := vfs.Mkdir(ctx, dir, 0777); err == nil {
			break
		} else if errors.Is(err, fs.ErrExist) {
			break
		} else if !errors.Is(err, fs.ErrNotExist) {
			// Some other error (permission, read-only, ...): report it; a
			// missing intermediate ancestor would also surface here as
			// ErrNotExist, which the next loop iteration's own Mkdir on the
			// parent will retry.
			missing = append(missing, dir)
		} else {
			missing = append(missing, dir)
		}
		parent := path.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}

	// Create the missing levels top-down so each Mkdir has an existing
	// parent; collecting bottom-up then reversing is what makes a deep
	// missing chain a single pass rather than one Stat per level.
	for i := len(missing) - 1; i >= 0; i-- {
		if err := vfs.Mkdir(ctx, missing[i], 0777); err != nil && !errors.Is(err, fs.ErrExist) {
			return err
		}
	}
	return nil
}
