package fileindexer

import (
	"context"
	"fmt"
	"log/slog"
	"path"
	"strings"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"go.uber.org/fx"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/logging"
)

type Consumer interface {
	Start() error
	Stop()
}

type consumer struct {
	log      *slog.Logger
	nc       *nats.Conn
	js       jetstream.JetStream
	consumer jetstream.Consumer
	ctx      jetstream.ConsumeContext

	files *mongo.Collection
}

type Params struct {
	fx.In

	Nc     *nats.Conn
	Js     jetstream.JetStream
	Db     *mongo.Database
	Logger *logging.Logger
	Mig    Migrations
}

func NewConsumer(p Params) (Consumer, error) {
	log := p.Logger.GetLogger("fileindexer")

	cfg := jetstream.StreamConfig{
		Name:     "SERAPH_FILE_INFO",
		Subjects: []string{events.FileProviderFileInfoTopic},
	}

	stream, err := p.Js.CreateOrUpdateStream(context.Background(), cfg)

	if err != nil {
		return nil, err
	}

	c, _ := stream.CreateOrUpdateConsumer(context.Background(), jetstream.ConsumerConfig{
		Durable: "SERAPH_FILE_INDEXER",
	})

	files := p.Db.Collection("files")

	return &consumer{
		log:      log,
		nc:       p.Nc,
		js:       p.Js,
		consumer: c,
		files:    files,
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

		if !strings.HasPrefix(fileInfoEvent.Path, "/") {
			c.log.Error("error processing FileInfoEvent: path is not absolute", "event", fileInfoEvent)
			msg.TermWithReason("path is not absolute")
			return
		}

		file := FilePrototype{}
		file.ProviderId.Set(fileInfoEvent.ProviderID)
		file.Path.Set(path.Clean(fileInfoEvent.Path))
		file.IsDir.Set(fileInfoEvent.IsDir)
		if fileInfoEvent.ModTime != 0 || fileInfoEvent.Mode != 0 || fileInfoEvent.Size != 0 {
			file.ModTime.Set(fileInfoEvent.ModTime)
			file.Mode.Set(fileInfoEvent.Mode)
			file.Size.Set(fileInfoEvent.Size)
		}
		if fileInfoEvent.Readdir != "" {
			file.Readdir.Set(fileInfoEvent.Readdir)
		}

		newFile, change, err := c.upsertFile(&file)

		if err != nil {
			c.log.Error("error processing FileInfoEvent", "error", err, "event", fileInfoEvent)
			return
		}

		if change != "" {
			err = c.publishChange(newFile, change)
			if err != nil {
				c.log.Error("error publishing FileChangedEvent", "error", err, "event", fileInfoEvent)
				return
			}
		}

		if fileInfoEvent.Readdir != "" && fileInfoEvent.Last {
			err = c.handleReaddirLast(newFile)
			if err != nil {
				c.log.Error("error handling readdir", "error", err, "event", fileInfoEvent)
				return
			}
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

func (c *consumer) upsertFile(file *FilePrototype) (newFile *File, change string, err error) {
	if file.Path.Get() != "/" { // if it's not the root dir
		dirName := path.Dir(file.Path.Get())
		parentDir := FilePrototype{}
		parentDir.ProviderId.Set(file.ProviderId.Get())
		parentDir.Path.Set(dirName)
		parentDir.IsDir.Set(true)
		var parent *File
		parent, _, err = c.upsertFile(&parentDir)
		if err != nil {
			return
		}
		file.ParentDir.Set(parent.Id)
		if parent.Readdir != "" && file.Readdir.IsDefined() && file.Readdir.Get() != parent.Readdir {
			file.Readdir.Unset()
		}
	}

	filter := FilePrototype{}
	filter.ProviderId.Set(file.ProviderId.Get())
	filter.Path.Set(file.Path.Get())

	update := bson.M{
		"$set": file,
	}
	opts := options.FindOneAndUpdate().SetUpsert(true).SetReturnDocument(options.Before)
	result := c.files.FindOneAndUpdate(context.Background(), filter, update, opts)
	resultNew := c.files.FindOne(context.Background(), filter)

	newFile = &File{}
	err = resultNew.Decode(newFile)

	if err != nil {
		return
	}

	if result.Err() == mongo.ErrNoDocuments {
		// file was newly created
		change = events.FileChangedEventCreated
	} else {
		var oldFile File
		err = result.Decode(&oldFile)
		if err != nil {
			return
		}
		if oldFile.ModTime != newFile.ModTime ||
			oldFile.Size != newFile.Size ||
			oldFile.Mode != newFile.Mode {
			change = events.FileChangedEventChanged
		}
	}
	return
}

func (c *consumer) publishChange(file *File, change string) error {
	ev := events.FileChangedEvent{
		Event: events.Event{
			ID:      uuid.NewString(),
			Version: 1,
		},
		Change:     change,
		FileID:     file.Id.Hex(),
		ProviderID: file.ProviderId,
		Path:       file.Path,
		Size:       file.Size,
		Mode:       file.Mode,
		ModTime:    file.ModTime,
		IsDir:      file.IsDir,
	}

	data, err := events.Api.Marshal(events.Schema, ev)

	if err != nil {
		return err
	}

	topic := fmt.Sprintf(events.FileChangedTopicPattern, file.Id.Hex())

	c.nc.Publish(topic, data)

	return nil
}

func (c *consumer) handleReaddirLast(file *File) error {
	var parentFilter FilePrototype
	parentFilter.Id.Set(file.ParentDir)
	parentResult := c.files.FindOne(context.Background(), parentFilter)

	if parentResult.Err() != nil {
		return parentResult.Err()
	}

	var parentDir File
	err := parentResult.Decode(&parentDir)
	if err != nil {
		return err
	}

	if parentDir.Readdir == "" {
		return fmt.Errorf("readdir has ended but parent directory '%s' has no active readdir", parentDir.Path)
	}

	if parentDir.Readdir != file.Readdir {
		// the readdir that ended is not the active readdir ... there ought to be another one ending
		return nil
	}

	deleteFilter := bson.M{
		"parentDir": parentDir.Id,
		"readdir": bson.M{
			"$ne": parentDir.Readdir,
		},
	}
	_, err = c.files.DeleteMany(context.Background(), deleteFilter)
	if err != nil {
		return err
	}

	var newParent FilePrototype
	newParent.Readdir.Set("")
	c.files.UpdateOne(context.Background(), parentFilter, newParent)

	return nil
}
