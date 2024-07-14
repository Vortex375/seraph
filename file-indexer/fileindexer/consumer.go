package fileindexer

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/nats-io/nats.go/jetstream"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/logging"
)

type Consumer interface {
	Start() error
	Stop()
}

type consumer struct {
	log      *slog.Logger
	js       jetstream.JetStream
	consumer jetstream.Consumer
	ctx      jetstream.ConsumeContext

	files *mongo.Collection
	dirs  *mongo.Collection
}

func NewConsumer(js jetstream.JetStream, db *mongo.Database, logger *logging.Logger, _ Migrations) (Consumer, error) {
	log := logger.GetLogger("fileindexer")

	cfg := jetstream.StreamConfig{
		Name:     "SERAPH_FILE_INFO",
		Subjects: []string{events.FileProviderFileInfoTopic},
	}

	stream, err := js.CreateOrUpdateStream(context.Background(), cfg)

	if err != nil {
		return nil, err
	}

	c, _ := stream.CreateOrUpdateConsumer(context.Background(), jetstream.ConsumerConfig{
		Durable: "SERAPH_FILE_INDEXER",
	})

	files := db.Collection("files")
	dirs := db.Collection("dirs")

	return &consumer{
		log:      log,
		js:       js,
		consumer: c,
		files:    files,
		dirs:     dirs,
	}, nil
}

func (c *consumer) Start() error {
	ctx, err := c.consumer.Consume(func(msg jetstream.Msg) {
		var rawEvent any
		fmt.Println("data:", msg.Data())
		err := events.Api.Unmarshal(events.Schema, msg.Data(), &rawEvent)
		if err != nil {
			c.log.Error("failed to deserialize message", "error", err)
			return
		}
		fileInfoEvent, ok := rawEvent.(events.FileInfoEvent)
		if !ok {
			c.log.Error("unexpected event type", "event", rawEvent)
			return
		}

		if fileInfoEvent.IsDir {
			//TODO: it's a dir
		} else {
			err = c.UpsertFile(fileInfoEvent)
		}
		if err != nil {
			c.log.Error("error processing FileInfoEvent", "error", err, "event", fileInfoEvent)
			return
		}

		c.log.Debug("successfully processed file event", "event", fileInfoEvent)
		msg.Ack()
	})
	if err != nil {
		return err
	}
	c.ctx = ctx
	return nil
}

func (c *consumer) Stop() {
	if c.ctx != nil {
		c.ctx.Drain()
	}
}

func (c *consumer) UpsertFile(e events.FileInfoEvent) error {
	filter := bson.M{
		"providerId": e.FileProviderEvent.ProviderID,
		"path":       e.Name,
	}
	update := bson.M{
		"$set": bson.M{
			"providerId": e.FileProviderEvent.ProviderID,
			"path":       e.Name,
		},
	}
	opts := options.Update().SetUpsert(true)
	_, err := c.files.UpdateOne(context.Background(), filter, update, opts)

	return err
}
