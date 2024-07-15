package fileindexer

import (
	"context"
	"log/slog"
	"path"
	"strings"

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

		err := events.Api.Unmarshal(events.Schema, msg.Data(), &rawEvent)
		if err != nil {
			c.log.Error("failed to deserialize message", "error", err)
			return
		}

		fileInfoEvent, ok := rawEvent.(events.FileInfoEvent)
		if !ok {
			c.log.Error("unexpected event type", "event", rawEvent)
			msg.TermWithReason("unexpected event type")
			return
		}

		if !strings.HasPrefix(fileInfoEvent.Name, "/") {
			c.log.Error("error processing FileInfoEvent: path is not absolute", "event", fileInfoEvent)
			msg.TermWithReason("path is not absolute")
			return
		}

		_, err = c.UpsertFile(&File{
			ProviderId: fileInfoEvent.FileProviderEvent.ProviderID,
			Path:       path.Clean(fileInfoEvent.Name),
			IsDir:      fileInfoEvent.IsDir,
		})

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

func (c *consumer) UpsertFile(file *File) (*File, error) {

	if file.Path != "/" { // if it's not the root dir
		dirName := path.Dir(file.Path)
		parent, err := c.UpsertFile(&File{
			ProviderId: file.ProviderId,
			Path:       dirName,
			IsDir:      true,
		})
		if err != nil {
			return nil, err
		}
		file.ParentDir = parent.Id
	}

	filter := bson.M{
		"providerId": file.ProviderId,
		"path":       file.Path,
	}
	update := bson.M{
		"$set": file,
	}
	opts := options.FindOneAndUpdate().SetUpsert(true).SetReturnDocument(options.After)
	result := c.files.FindOneAndUpdate(context.Background(), filter, update, opts)

	var updatedFile File
	err := result.Decode(&updatedFile)

	return &updatedFile, err
}
