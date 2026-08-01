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

// listPage executes a single bounded range scan over the compound
// (providerId, path) index, returning at most pageSize entries beneath
// prefix, ordered by path so that paging is stable.
//
// The range bounds are computed so that this is a plain range scan on the
// existing unique compound index -- no regex, no collection scan. Prefix
// matching respects directory boundaries: a prefix of "/Photos" matches
// "/Photos" itself and anything under "/Photos/...", but never a sibling
// like "/Photos2".
func (l *list) listPage(ctx context.Context, providerId string, prefix string, cursor string, pageSize int) (entries []events.FileIndexListEntry, nextCursor string, hasMore bool, err error) {
	entries = []events.FileIndexListEntry{}

	if providerId == "" {
		return
	}

	lower, upper, ok := prefixRange(prefix)
	if !ok {
		// empty or malformed prefix -> empty page, not an error
		return
	}

	// lower bound of the range: the prefix itself, unless a cursor from a
	// previous page moves it further along -- either way this stays a
	// single bounded range on the (providerId, path) index.
	lowerOp := "$gte"
	lowerBound := lower
	if cursor != "" && cursor > lower {
		lowerOp = "$gt"
		lowerBound = cursor
	}

	pathFilter := bson.M{lowerOp: lowerBound, "$lt": upper}

	filter := bson.M{
		"providerId": providerId,
		"path":       pathFilter,
	}

	// fetch one extra document to determine whether another page follows
	findOpts := options.Find().
		SetSort(bson.D{{Key: "providerId", Value: 1}, {Key: "path", Value: 1}}).
		SetLimit(int64(pageSize) + 1)

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

	if len(files) > pageSize {
		hasMore = true
		files = files[:pageSize]
	}

	for _, f := range files {
		entries = append(entries, events.FileIndexListEntry{
			ProviderId: f.ProviderId,
			Path:       f.Path,
			Size:       f.Size,
			ModTime:    f.ModTime,
			IsDir:      f.IsDir,
			Mime:       f.Mime,
		})
	}

	if hasMore && len(files) > 0 {
		nextCursor = files[len(files)-1].Path
	}

	return
}

// prefixRange computes the [lower, upper) bounds on the path field that
// select exactly the prefix path itself plus every descendant beneath it,
// while excluding any sibling whose name merely starts with the same
// characters (e.g. prefix "/Photos" must not match "/Photos2").
//
// The bounds rely only on lexicographic ordering (no regex), so a query
// built from them is a plain range scan on the (providerId, path) index.
func prefixRange(prefix string) (lower string, upper string, ok bool) {
	if prefix == "" {
		return "", "", false
	}

	clean := path.Clean(prefix)
	if clean == "." || clean == "" {
		return "", "", false
	}

	if clean == "/" {
		// everything is beneath the root
		return "/", "0", true
	}

	// lower bound includes the prefix path itself...
	lower = clean
	// ...and everything nested beneath it, delimited by "/".
	// upper bound is exclusive: it is the smallest string greater than
	// every path starting with clean+"/", but not greater than any
	// sibling such as clean+"2". Since '/' (0x2F) is immediately followed
	// by '0' (0x30) in ASCII/UTF-8 byte ordering, and no path segment can
	// contain a NUL or "/" itself, clean+"0" is exactly that bound.
	upper = clean + "0"

	return lower, upper, true
}
