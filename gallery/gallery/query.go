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

package gallery

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"path"
	"strconv"
	"strings"

	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo/options"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/spaces/spaces"
)

// resolvedFolder is one of the requesting user's Gallery Source Folders,
// resolved to a physical prefix FOR THAT USER at query time.
//
// This is the only access-control mechanism the listing query has: a folder
// that fails to resolve (Space deleted, access revoked since the folder was
// configured) simply is not in this slice and therefore contributes no
// photos - there is no separate permission check, and no reverse
// physical-to-space index to keep in sync with one.
type resolvedFolder struct {
	// physical location every matching GalleryPhoto is found under
	providerId string
	path       string // cleaned, no trailing slash except root "/"

	// SPACE coordinates to translate a physical match back to, so the API
	// can return a path the app can feed straight into preview/download
	spaceProviderId string
	spacePath       string // GallerySourceFolder.Path, cleaned
}

// contains reports whether the physical (providerId, filePath) falls under
// this resolved folder, and if so, the remainder of filePath below the
// folder's physical root (the part to append to spacePath to translate it).
func (f resolvedFolder) contains(providerId string, filePath string) (rest string, ok bool) {
	if f.providerId != providerId {
		return "", false
	}
	if f.path == "/" {
		return filePath, true
	}
	if filePath == f.path {
		return "", true
	}
	if strings.HasPrefix(filePath, f.path+"/") {
		return strings.TrimPrefix(filePath, f.path), true
	}
	return "", false
}

// toSpacePath translates a physical path known to be under this folder (see
// contains) into the SPACE path the API returns.
func (f resolvedFolder) toSpacePath(rest string) string {
	return joinSpacePath(f.spacePath, rest)
}

func joinSpacePath(spacePath string, rest string) string {
	p := path.Join(spacePath, rest)
	if p == "" || p == "." {
		p = "/"
	}
	if !strings.HasPrefix(p, "/") {
		p = "/" + p
	}
	return p
}

// resolveFoldersForUser resolves every Gallery Source Folder configured by
// userId, for userId, right now. Unlike the ingestion prefix cache (which is
// shared across users and refreshed periodically for cheap event matching),
// this always issues a fresh SpaceResolveRequest per folder: it is the
// query's access-control check, so it must reflect the requesting user's
// CURRENT access, not a cached view that might still include a folder whose
// access was revoked moments ago.
func (g *GalleryProvider) resolveFoldersForUser(ctx context.Context, userId string) ([]resolvedFolder, error) {
	cur, err := g.sourceFolders.Find(ctx, bson.M{"userId": userId})
	if err != nil {
		return nil, fmt.Errorf("while listing gallery source folders for %s: %w", userId, err)
	}

	folders := make([]GallerySourceFolder, 0)
	if err := cur.All(ctx, &folders); err != nil {
		return nil, fmt.Errorf("while listing gallery source folders for %s: %w", userId, err)
	}

	resolved := make([]resolvedFolder, 0, len(folders))
	for _, f := range folders {
		req := spaces.SpaceResolveRequest{
			UserId:          f.UserId,
			SpaceProviderId: f.SpaceProviderId,
		}
		res := spaces.SpaceResolveResponse{}
		if err := messaging.Request(ctx, g.nc, spaces.SpaceResolveTopic, messaging.Json(&req), messaging.Json(&res)); err != nil {
			g.log.Warn("failed to resolve gallery source folder for listing; excluding it from this query",
				"error", err, "userId", f.UserId, "spaceProviderId", f.SpaceProviderId, "path", f.Path)
			continue
		}
		// Revoked access surfaces here as an empty/errored resolve response,
		// exactly like the ingestion side (refreshPrefixCache) and the ADD
		// access check (checkAccess): resolution failing IS the
		// access-control decision, applied fresh for this user on this
		// query.
		if res.Error != "" || res.ProviderId == "" {
			g.log.Debug("gallery source folder does not resolve for listing; excluding it",
				"error", res.Error, "userId", f.UserId, "spaceProviderId", f.SpaceProviderId, "path", f.Path)
			continue
		}

		physicalPath := path.Join(res.Path, f.Path)
		if physicalPath == "" {
			physicalPath = "/"
		}

		resolved = append(resolved, resolvedFolder{
			providerId:      res.ProviderId,
			path:            physicalPath,
			spaceProviderId: f.SpaceProviderId,
			spacePath:       f.Path,
		})
	}

	return resolved, nil
}

// translate maps a physical (providerId, path) to the SPACE coordinates of
// the first resolved folder that contains it. Multiple configured folders
// could in principle overlap (e.g. a folder and a sub-folder both added);
// the first match in the user's own folder list wins, which is deterministic
// given a stable folder order and does not affect which photos are returned,
// only which of several equally-valid space paths is shown for them.
func translate(folders []resolvedFolder, providerId string, filePath string) (spaceProviderId string, spacePath string, ok bool) {
	for _, f := range folders {
		if rest, matched := f.contains(providerId, filePath); matched {
			return f.spaceProviderId, f.toSpacePath(rest), true
		}
	}
	return "", "", false
}

// listCursor is the decoded form of a GalleryListRequest.Cursor: a position
// in the (capturedAt desc, _id asc) keyset the query is paged over. Encoding
// it as an opaque string (rather than exposing capturedAt/_id directly)
// keeps the wire format free to change later.
type listCursor struct {
	capturedAt int64
	id         primitive.ObjectID
}

func encodeCursor(capturedAt int64, id primitive.ObjectID) string {
	raw, _ := json.Marshal([2]string{strconv.FormatInt(capturedAt, 10), id.Hex()})
	return base64.RawURLEncoding.EncodeToString(raw)
}

func decodeCursor(s string) (listCursor, error) {
	if s == "" {
		return listCursor{}, nil
	}
	raw, err := base64.RawURLEncoding.DecodeString(s)
	if err != nil {
		return listCursor{}, fmt.Errorf("invalid cursor: %w", err)
	}
	var parts [2]string
	if err := json.Unmarshal(raw, &parts); err != nil {
		return listCursor{}, fmt.Errorf("invalid cursor: %w", err)
	}
	capturedAt, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return listCursor{}, fmt.Errorf("invalid cursor: %w", err)
	}
	id, err := primitive.ObjectIDFromHex(parts[1])
	if err != nil {
		return listCursor{}, fmt.Errorf("invalid cursor: %w", err)
	}
	return listCursor{capturedAt: capturedAt, id: id}, nil
}

// scanBatchSize bounds how many read-model documents are pulled from Mongo
// per underlying find() while assembling one page of the listing. The read
// model is shared across all users and keyed physically, so it cannot be
// filtered by an index on the requesting user - membership in this user's
// folders is a small, in-memory prefix check applied to candidates fetched
// in (capturedAt desc, _id) order. A larger batch means fewer round trips
// when a user's folders cover a small fraction of a large shared read model.
const scanBatchSize = 500

// listPhotos returns one page of userId's gallery listing, Capture-Date
// ordered (newest first), translated to SPACE paths.
//
// Paging is a keyset/seek cursor over the (capturedAt desc, _id) index -
// never skip/limit - so results stay stable (no skips, no duplicates,
// including across photos that share a Capture Date) no matter how many
// photos exist or how many pages are fetched. The index that backs this
// query (galleryPhotos_capturedAt_id_idx) exists specifically for it.
//
// Because the read model is shared and keyed physically, "this user's
// photos" is not a filter Mongo can apply via an index: candidates are
// fetched from the capturedAt-ordered index in batches and matched in memory
// against the user's resolved folders (typically a handful), continuing
// until a full page is assembled or the read model is exhausted. This keeps
// the emitted order exactly the index order - the property the cursor
// depends on - rather than re-sorting a filtered subset.
func (g *GalleryProvider) listPhotos(ctx context.Context, req *GalleryListRequest) *GalleryListResponse {
	if req.UserId == "" {
		return &GalleryListResponse{Error: "userId is required"}
	}

	pageSize := req.PageSize
	if pageSize <= 0 {
		pageSize = DefaultListPageSize
	}
	if pageSize > MaxListPageSize {
		pageSize = MaxListPageSize
	}

	cursor, err := decodeCursor(req.Cursor)
	if err != nil {
		return &GalleryListResponse{Error: err.Error()}
	}

	folders, err := g.resolveFoldersForUser(ctx, req.UserId)
	if err != nil {
		return &GalleryListResponse{Error: err.Error()}
	}
	if len(folders) == 0 {
		// no accessible folders -> empty listing, not an error: this is the
		// ordinary state for a user who has configured nothing, and it is
		// also what a user whose only folder just had its access revoked
		// sees, indistinguishably.
		return &GalleryListResponse{Items: []GalleryListItem{}}
	}

	items := make([]GalleryListItem, 0, pageSize)
	// pos/havePos track the seek position of the last read-model document
	// EXAMINED so far (matched or not: skipped documents - deleted, or
	// outside every resolved folder - still advance the seek, exactly like
	// they would in a plain unfiltered keyset scan). This is what
	// NextCursor is built from: it is always a real position in the
	// (capturedAt desc, _id) index, so resuming from it can never skip or
	// repeat a document, independent of how the in-memory folder filter
	// happens to thin out any given batch.
	pos := cursor
	havePos := cursor != (listCursor{})
	exhausted := false

	for len(items) < pageSize && !exhausted {
		filter := seekFilter(pos, havePos)
		findOpts := options.Find().
			SetSort(listSort).
			SetLimit(int64(scanBatchSize))

		cur, findErr := g.photos.Find(ctx, filter, findOpts)
		if findErr != nil {
			return &GalleryListResponse{Error: findErr.Error()}
		}

		var batch []GalleryPhoto
		decodeErr := cur.All(ctx, &batch)
		cur.Close(ctx)
		if decodeErr != nil {
			return &GalleryListResponse{Error: decodeErr.Error()}
		}

		// batchFullyWalked distinguishes "reached the end of this batch"
		// from "stopped partway because the page filled up". Only in the
		// former case does a short batch (len(batch) < scanBatchSize) prove
		// there is nothing left beyond it - stopping early leaves the rest
		// of the batch unexamined, so exhausted must not be inferred from
		// its length in that case.
		batchFullyWalked := true

		for _, p := range batch {
			pos = listCursor{capturedAt: p.CapturedAt, id: p.Id}
			havePos = true

			if p.Deleted {
				continue
			}
			spaceProviderId, spacePath, ok := translate(folders, p.ProviderId, p.Path)
			if !ok {
				continue
			}

			items = append(items, GalleryListItem{
				ProviderId:       spaceProviderId,
				Path:             spacePath,
				CapturedAt:       p.CapturedAt,
				CapturedAtSource: p.CapturedAtSource,
				Width:            p.Width,
				Height:           p.Height,
				Orientation:      p.Orientation,
				Size:             p.Size,
				Mime:             p.Mime,
				Unsupported:      p.Unsupported,
			})

			if len(items) == pageSize {
				batchFullyWalked = false
				break
			}
		}

		if batchFullyWalked && len(batch) < scanBatchSize {
			// walked the whole batch and it was short: the read model has
			// nothing left beyond it
			exhausted = true
		}
	}

	resp := &GalleryListResponse{Items: items}
	if len(items) == pageSize && !exhausted {
		resp.HasMore = true
		resp.NextCursor = encodeCursor(pos.capturedAt, pos.id)
	}
	return resp
}

// listSort is the page ordering: newest Capture Date first, ties broken by
// _id so the order (and therefore the cursor) is total and stable.
var listSort = bson.D{{Key: "capturedAt", Value: -1}, {Key: "_id", Value: 1}}

// seekFilter builds the keyset/seek predicate for the next batch: strictly
// past the given cursor position in (capturedAt desc, _id asc) order, or
// unconstrained for the first batch. This is what makes paging a seek
// rather than a skip: every batch is a fresh bounded range scan on
// galleryPhotos_capturedAt_id_idx starting exactly where the previous one
// left off, so no item can be skipped or repeated regardless of how many
// batches or pages are fetched.
func seekFilter(pos listCursor, have bool) bson.M {
	if !have {
		return bson.M{}
	}
	// capturedAt is descending, so "past" this position means either a
	// strictly smaller capturedAt, or the same capturedAt with a strictly
	// greater _id (the tie-break order).
	return bson.M{
		"$or": []bson.M{
			{"capturedAt": bson.M{"$lt": pos.capturedAt}},
			{"capturedAt": pos.capturedAt, "_id": bson.M{"$gt": pos.id}},
		},
	}
}
