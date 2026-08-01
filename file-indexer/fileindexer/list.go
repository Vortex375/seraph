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

package fileindexer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"path"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"go.opentelemetry.io/otel/trace"
	"go.uber.org/fx"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/tracing"
)

// DefaultListPageSize is used when a request does not specify a positive
// PageSize.
const DefaultListPageSize = 500

// MaxListPageSize caps the number of entries returned in a single page,
// regardless of what the request asks for.
const MaxListPageSize = 5000

type ListParams struct {
	fx.In

	Nc      *nats.Conn
	Db      *mongo.Database
	Logger  *logging.Logger
	Tracing *tracing.Tracing
	Mig     Migrations
	Lc      fx.Lifecycle
}

type List interface{}

type list struct {
	log    *slog.Logger
	nc     *nats.Conn
	files  *mongo.Collection
	tracer trace.Tracer

	requestChan chan *nats.Msg
	requestSub  *nats.Subscription
}

func NewList(p ListParams) (List, error) {
	log := p.Logger.GetLogger("file-list")
	files := p.Db.Collection(filesCollection)
	tracer := p.Tracing.TracerProvider.Tracer("file-list")

	l := &list{
		log:    log,
		nc:     p.Nc,
		files:  files,
		tracer: tracer,
	}

	p.Lc.Append(fx.StartHook(l.start))
	p.Lc.Append(fx.StopHook(l.stop))

	return l, nil
}

func (l *list) start() error {
	l.requestChan = make(chan *nats.Msg, nats.DefaultSubPendingMsgsLimit)
	sub, err := l.nc.ChanSubscribe(events.FileIndexListRequestTopic, l.requestChan)
	if err != nil {
		return err
	}
	l.requestSub = sub

	go l.messageLoop()

	return nil
}

func (l *list) stop() {
	if l.requestSub != nil {
		l.requestSub.Unsubscribe()
		l.requestSub = nil
	}
	if l.requestChan != nil {
		close(l.requestChan)
	}
}

func (l *list) messageLoop() {
	for {
		msg, ok := <-l.requestChan
		if !ok {
			return
		}
		go l.handleMessage(msg)
	}
}

func (l *list) handleMessage(msg *nats.Msg) {
	ctx := messaging.ExtractTraceContext(context.Background(), msg)
	ctx, span := l.tracer.Start(ctx, "handleListRequest")
	defer span.End()

	req := events.FileIndexListRequest{}
	err := json.Unmarshal(msg.Data, &req)
	if err != nil {
		l.log.Error("invalid request", "error", err)
		return
	}

	replyId := uuid.NewString()
	ackTopic := fmt.Sprintf(events.FileIndexListAckTopicPattern, req.RequestId)
	replyTopic := fmt.Sprintf(events.FileIndexListReplyTopicPattern, req.RequestId)

	l.log.Debug("ack list request", "requestId", req.RequestId, "replyId", replyId, "providerId", req.ProviderId, "path", req.Path)
	ack := events.FileIndexListAck{
		RequestId: req.RequestId,
		ReplyId:   replyId,
		Ack:       true,
	}
	data, _ := json.Marshal(ack)
	l.nc.Publish(ackTopic, data)

	pageSize := req.PageSize
	if pageSize <= 0 {
		pageSize = DefaultListPageSize
	}
	if pageSize > MaxListPageSize {
		pageSize = MaxListPageSize
	}

	entries, nextCursor, hasMore, err := l.listPage(ctx, req.ProviderId, req.Path, req.Cursor, pageSize)
	if err != nil {
		l.log.Error("error while executing list query", "error", err)
		l.replyError(req.RequestId, replyId, err)
		return
	}

	reply := events.FileIndexListReply{
		RequestId:  req.RequestId,
		ReplyId:    replyId,
		Entries:    entries,
		NextCursor: nextCursor,
		HasMore:    hasMore,
		Last:       true,
	}
	data, _ = json.Marshal(reply)
	l.nc.Publish(replyTopic, data)
}

func (l *list) replyError(requestId string, replyId string, err error) {
	replyTopic := fmt.Sprintf(events.FileIndexListReplyTopicPattern, requestId)
	errReply := events.FileIndexListReply{
		RequestId: requestId,
		ReplyId:   replyId,
		Error:     err.Error(),
		Last:      true,
	}
	data, _ := json.Marshal(errReply)
	l.nc.Publish(replyTopic, data)
}

// listPage returns at most pageSize entries at or beneath prefix, ordered
// by path so that paging is stable.
//
// The prefix selects two disjoint pieces of the key space: the prefix path
// itself, and the half-open range [prefix+"/", prefix+"0") of descendants.
// They are queried separately, as one point lookup plus one range scan,
// rather than combined with an $or: MongoDB answers such an $or by scanning
// the whole provider's key space with the $or as a residual filter (an
// IXSCAN with [MinKey, MaxKey] path bounds), which defeats the point of the
// bound. Issued separately, each query keeps tight index bounds.
//
// Either way no regex is involved, so prefix matching cannot silently
// degrade to a collection scan, and directory boundaries hold in both
// directions: a prefix of "/Photos" matches "/Photos" and anything under
// "/Photos/...", but never "/Photos2", "/Photos.txt" or "/Photos-old".
func (l *list) listPage(ctx context.Context, providerId string, prefix string, cursor string, pageSize int) (entries []events.FileIndexListEntry, nextCursor string, hasMore bool, err error) {
	entries = []events.FileIndexListEntry{}

	if providerId == "" {
		return
	}
	exact, _, _, ok := prefixRange(prefix)
	if !ok {
		// empty/unknown prefix -> empty page, not an error
		return
	}

	remaining := pageSize

	// The prefix path itself only ever belongs on the first page: it sorts
	// before all of its descendants, so any cursor is already past it.
	if cursor == "" && exact != "" {
		selfFilter, _ := buildPrefixSelfFilter(providerId, prefix)
		var self File
		decodeErr := l.files.FindOne(ctx, selfFilter).Decode(&self)
		if decodeErr == nil {
			entries = append(entries, toListEntry(self))
			remaining--
		} else if !errors.Is(decodeErr, mongo.ErrNoDocuments) {
			err = decodeErr
			return
		}
	}

	filter, ok := buildDescendantsFilter(providerId, prefix, cursor)
	if !ok {
		// cursor is past the end of the prefix range
		return
	}

	// fetch one extra document to determine whether another page follows
	findOpts := options.Find().
		SetSort(listSort).
		SetLimit(int64(remaining) + 1)

	cur, findErr := l.files.Find(ctx, filter, findOpts)
	if findErr != nil {
		err = findErr
		return
	}
	defer cur.Close(ctx)

	var files []File
	if decodeErr := cur.All(ctx, &files); decodeErr != nil {
		err = decodeErr
		return
	}

	if len(files) > remaining {
		hasMore = true
		files = files[:remaining]
	}

	for _, f := range files {
		entries = append(entries, toListEntry(f))
	}

	// the cursor is the last path of the page as a whole, which may be the
	// prefix entry itself when the page had no room left for descendants
	if hasMore && len(entries) > 0 {
		nextCursor = entries[len(entries)-1].Path
	}

	return
}

func toListEntry(f File) events.FileIndexListEntry {
	return events.FileIndexListEntry{
		ProviderId: f.ProviderId,
		Path:       f.Path,
		Size:       f.Size,
		ModTime:    f.ModTime,
		IsDir:      f.IsDir,
		Mime:       f.Mime,
	}
}

// buildPrefixSelfFilter matches the prefix path itself: an equality match
// on both index fields, i.e. a point lookup on (providerId, path).
func buildPrefixSelfFilter(providerId string, prefix string) (bson.M, bool) {
	if providerId == "" {
		return nil, false
	}
	exact, _, _, ok := prefixRange(prefix)
	if !ok || exact == "" {
		return nil, false
	}
	return bson.M{"providerId": providerId, "path": exact}, true
}

// buildDescendantsFilter matches everything strictly beneath the prefix as
// the half-open path range [prefix+"/", prefix+"0"), narrowed by the paging
// cursor. Equality on providerId plus a range on path is exactly the shape
// the (providerId, path) index is ordered by, so this stays a bounded range
// scan.
//
// ok is false when the request can only ever match nothing: no provider, no
// prefix, or a cursor already past the end of the range.
func buildDescendantsFilter(providerId string, prefix string, cursor string) (bson.M, bool) {
	if providerId == "" {
		return nil, false
	}

	_, lower, upper, ok := prefixRange(prefix)
	if !ok {
		return nil, false
	}

	lowerOp := "$gte"
	lowerBound := lower
	if cursor != "" && cursor > lower {
		// continue strictly after the last path of the previous page
		lowerOp = "$gt"
		lowerBound = cursor
	}
	if lowerBound >= upper {
		return nil, false
	}

	return bson.M{
		"providerId": providerId,
		"path":       bson.M{lowerOp: lowerBound, "$lt": upper},
	}, true
}

// listSort is the page ordering: the (providerId, path) index order, which
// is what makes the path cursor stable across pages.
var listSort = bson.D{{Key: "providerId", Value: 1}, {Key: "path", Value: 1}}

// prefixRange decomposes a prefix into the pieces of the path key space
// that belong to it: the exact prefix path, plus the half-open range
// [lower, upper) holding every descendant beneath it.
//
// Directory boundaries are respected in both directions. Descendants are
// delimited by "/", so lower is clean+"/". The exclusive upper bound is
// clean+"0": '/' (0x2F) is immediately followed by '0' (0x30) in byte
// order, so the range covers every path starting with clean+"/" and
// nothing else. Siblings are therefore excluded whether they sort above
// the boundary (e.g. "/Photos2", '2' = 0x32) or below it (e.g.
// "/Photos.txt", '.' = 0x2E, or "/Photos-old", '-' = 0x2D) -- the latter
// fall outside [lower, upper) because they are below lower, which is why
// the exact prefix must be matched separately rather than by opening the
// bottom of the range.
//
// The bounds rely only on lexicographic ordering (no regex), so a query
// built from them is a bounded range scan on the (providerId, path) index.
//
// An empty exact result means the prefix path needs no separate branch
// because the range already covers it (the root case).
func prefixRange(prefix string) (exact string, lower string, upper string, ok bool) {
	if prefix == "" {
		return "", "", "", false
	}

	clean := path.Clean(prefix)
	if clean == "." || clean == "" {
		return "", "", "", false
	}

	if clean == "/" {
		// Everything is beneath the root, and the root path "/" itself
		// already sorts at the bottom of that range, so no separate
		// exact branch is needed.
		return "", "/", "0", true
	}

	return clean, clean + "/", clean + "0", true
}
