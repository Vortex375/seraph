package fileindexer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"strings"

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
	"umbasa.net/seraph/spaces/spaces"
	"umbasa.net/seraph/tracing"
)

type SearchParams struct {
	fx.In

	Nc      *nats.Conn
	Db      *mongo.Database
	Logger  *logging.Logger
	Tracing *tracing.Tracing
	Mig     Migrations
	Lc      fx.Lifecycle
}

type Search interface{}

type search struct {
	log    *slog.Logger
	nc     *nats.Conn
	files  *mongo.Collection
	tracer trace.Tracer

	requestChan chan *nats.Msg
	requestSub  *nats.Subscription
}

func NewSearch(p SearchParams) (Search, error) {
	log := p.Logger.GetLogger("file-search")
	files := p.Db.Collection(filesCollection)
	tracer := p.Tracing.TracerProvider.Tracer("file-search")

	search := &search{
		log:    log,
		nc:     p.Nc,
		files:  files,
		tracer: tracer,
	}

	p.Lc.Append(fx.StartHook(search.start))
	p.Lc.Append(fx.StopHook(search.stop))

	return search, nil
}

func (s *search) start() error {
	s.requestChan = make(chan *nats.Msg, nats.DefaultSubPendingMsgsLimit)
	sub, err := s.nc.ChanSubscribe(events.SearchRequestTopic, s.requestChan)
	if err != nil {
		return err
	}
	s.requestSub = sub

	go s.messageLoop()

	return nil
}

func (s *search) stop() {
	if s.requestSub != nil {
		s.requestSub.Unsubscribe()
		s.requestSub = nil
	}
	if s.requestChan != nil {
		close(s.requestChan)
	}
}

func (s *search) messageLoop() {
	for {
		msg, ok := <-s.requestChan
		if !ok {
			return
		}
		go s.handleMessage(msg)
	}
}

func (s *search) handleMessage(msg *nats.Msg) {
	ctx := messaging.ExtractTraceContext(context.Background(), msg)

	req := events.SearchRequest{}
	err := json.Unmarshal(msg.Data, &req)
	if err != nil {
		s.log.Error("invalid request", "error", err)
		return
	}

	replyId := uuid.NewString()
	ackTopic := fmt.Sprintf(events.SearchAckTopicPattern, req.RequestId)
	replyTopic := fmt.Sprintf(events.SearchReplyTopicPattern, req.RequestId)
	if slices.Index(req.Types, events.SearchTypeFiles) < 0 {
		s.log.Debug("nack search request", "requestId", req.RequestId, "replyId", replyId, "types", req.Types, "query", req.Query)
		nack := events.SearchAck{
			RequestId: req.RequestId,
			ReplyId:   replyId,
			Ack:       false,
		}
		data, _ := json.Marshal(nack)
		s.nc.Publish(ackTopic, data)
		return
	}

	s.log.Debug("ack search request", "requestId", req.RequestId, "replyId", replyId, "types", req.Types, "query", req.Query)
	ack := events.SearchAck{
		RequestId: req.RequestId,
		ReplyId:   replyId,
		Ack:       true,
		Types:     []string{events.SearchTypeFiles},
	}
	data, _ := json.Marshal(ack)
	s.nc.Publish(ackTopic, data)

	userSpaces, err := spaces.GetSpacesForUser(ctx, s.nc, req.UserId)
	if err != nil {
		s.log.Error("error while retrieving spaces for user", "error", err)
		s.replyError(req.RequestId, replyId, err)
		return
	}
	if len(userSpaces) == 0 {
		s.log.Warn("no spaces found for user " + req.UserId)
		s.replyError(req.RequestId, replyId, errors.New("no spaces found"))
		return
	}

	providerFilterList := bson.A{}
	for _, space := range userSpaces {
		for _, provider := range space.FileProviders {
			providerFilter := bson.M{
				"providerId": provider.ProviderId,
			}
			if provider.Path != "" {
				providerFilter["path"] = bson.M{"$regex": fmt.Sprintf("^%s", provider.Path)}
			}
			providerFilterList = append(providerFilterList, providerFilter)
		}
	}

	filter := bson.M{
		"$and": bson.A{
			bson.M{"$or": providerFilterList},
			bson.M{"$text": bson.M{"$search": req.Query}},
		},
	}
	projection := bson.M{"score": bson.M{"$meta": "textScore"}}

	s.log.Debug("search query", "query", logging.JsonValue(filter))

	cur, err := s.files.Find(ctx, filter, options.Find().SetProjection(projection).SetSort(projection))
	if err != nil {
		s.log.Error("error while executing search query", "error", err)
		s.replyError(req.RequestId, replyId, err)
		return
	}
	defer cur.Close(ctx)

	for cur.Next(ctx) {
		err := cur.Err()
		if err != nil {
			s.log.Error("error while retrieving query results", "error", err)
			s.replyError(req.RequestId, replyId, err)
			return
		}
		file := File{}
		err = cur.Decode(&file)
		if err != nil {
			s.log.Error("error while decoding query results", "error", err)
			s.replyError(req.RequestId, replyId, err)
			return
		}
		s.mapSpace(userSpaces, &file)
		reply := events.SearchReply{
			RequestId: req.RequestId,
			ReplyId:   replyId,
			Type:      events.SearchTypeFiles,
			Reply: map[string]any{
				"providerId": file.ProviderId,
				"path":       file.Path,
			},
		}
		data, _ := json.Marshal(reply)
		s.nc.Publish(replyTopic, data)
	}
	reply := events.SearchReply{
		RequestId: req.RequestId,
		ReplyId:   replyId,
		Last:      true,
	}
	data, _ = json.Marshal(reply)
	s.nc.Publish(replyTopic, data)
}

func (s *search) replyError(requestId string, replyId string, err error) {
	replyTopic := fmt.Sprintf(events.SearchReplyTopicPattern, requestId)
	errReply := events.SearchReply{
		RequestId: requestId,
		ReplyId:   replyId,
		Error:     err.Error(),
	}
	data, _ := json.Marshal(errReply)
	s.nc.Publish(replyTopic, data)
}

func (s *search) mapSpace(userSpaces []spaces.Space, file *File) {
	for _, space := range userSpaces {
		for _, provider := range space.FileProviders {
			if provider.ProviderId == file.ProviderId && strings.HasPrefix(file.Path, provider.Path) {
				file.ProviderId = provider.SpaceProviderId
				file.Path = file.Path[len(provider.Path):]
				file.Path = strings.TrimLeft(file.Path, "/")
			}
		}
	}
}
