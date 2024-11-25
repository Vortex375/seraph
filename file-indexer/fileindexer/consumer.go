package fileindexer

import (
	"context"
	"fmt"
	"log/slog"
	"mime"
	"os"
	"path"
	"strings"

	"github.com/gabriel-vasile/mimetype"
	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"go.uber.org/fx"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"
)

type Consumer interface {
	Start() error
	Stop()
}

type consumer struct {
	logger   *logging.Logger
	log      *slog.Logger
	nc       *nats.Conn
	js       jetstream.JetStream
	consumer jetstream.Consumer
	ctx      jetstream.ConsumeContext

	files   *mongo.Collection
	readdir *mongo.Collection
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

	// create stream for FileChangedEvent - we are producer for these

	log.Debug("create " + events.FileChangedStream)
	cfg := jetstream.StreamConfig{
		Name:     events.FileChangedStream,
		Subjects: []string{events.FileChangedTopic},
	}

	_, err := p.Js.CreateOrUpdateStream(context.Background(), cfg)
	if err != nil {
		return nil, err
	}

	// create stream for FileInfoEvent - we consume these

	log.Debug("create " + events.FileInfoStream)
	cfg = jetstream.StreamConfig{
		Name:     events.FileInfoStream,
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
	readdir := p.Db.Collection("readdir")

	return &consumer{
		logger:   p.Logger,
		log:      log,
		nc:       p.Nc,
		js:       p.Js,
		consumer: c,
		files:    files,
		readdir:  readdir,
	}, nil
}

func (c *consumer) Start() error {
	ctx, err := c.consumer.Consume(func(msg jetstream.Msg) {
		fileInfoEvent := events.FileInfoEvent{}

		err := fileInfoEvent.Unmarshal(msg.Data())
		if err != nil {
			c.log.Error("failed to deserialize message", "error", err)
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

		newFile, change, err := c.upsertFile(&file)

		if err != nil {
			c.log.Error("error processing FileInfoEvent", "error", err, "event", fileInfoEvent)
			return
		}

		if change != "" {
			err = c.detectAndUpdateMime(newFile)
			if err != nil {
				c.log.Error("error storing mime type for file", "error", err, "event", fileInfoEvent)
				return
			}
			err = c.publishChange(newFile, change)
			if err != nil {
				c.log.Error("error publishing FileChangedEvent", "error", err, "event", fileInfoEvent)
				return
			}
		}

		if fileInfoEvent.Readdir != nil {
			c.handleReaddir(newFile, fileInfoEvent.Readdir)
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

func (c *consumer) detectAndUpdateMime(file *File) error {
	if file.IsDir {
		return nil
	}

	ext := path.Ext(file.Path)
	typ := mime.TypeByExtension(ext)

	if typ == "" {
		// use magic numbers for mimetype detection
		// slow, so we do it only when it can't be done from the file extension
		client := fileprovider.NewFileProviderClient(file.ProviderId, c.nc, c.logger)
		defer client.Close()
		inFile, err := client.OpenFile(context.TODO(), file.Path, os.O_RDONLY, 0)
		if err != nil {
			c.log.Error("Error while opening file for mime type detection", "path", file.Path, "error", err)
			return nil
		}
		defer inFile.Close()
		mimeType, err := mimetype.DetectReader(inFile)
		if err != nil {
			c.log.Error("Error while detecting mime type", "path", file.Path, "error", err)
			return nil
		}
		typ = mimeType.String()
	}

	c.log.Debug("Identified mime type", "path", file.Path, "mime", typ)

	filter := FilePrototype{}
	filter.Id.Set(file.Id)

	proto := FilePrototype{}
	proto.Mime.Set(typ)

	_, err := c.files.UpdateOne(context.Background(), filter, bson.M{"$set": proto})
	if err != nil {
		return err
	}

	file.Mime = typ

	return nil
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
		Mime:       file.Mime,
	}

	data, err := ev.Marshal()

	if err != nil {
		return err
	}

	topic := fmt.Sprintf(events.FileChangedTopicPattern, file.Id.Hex())

	c.nc.Publish(topic, data)

	return nil
}

func (c *consumer) handleReaddir(file *File, readDir *events.ReadDir) error {
	opts := options.Update().SetUpsert(true)

	filter := ReaddirPrototype{}
	filter.Readdir.Set(readDir.Readdir)
	filter.Index.Set(readDir.Index)

	proto := filter
	proto.Total.Set(readDir.Total)
	proto.File.Set(file.Id)
	proto.ParentDir.Set(file.ParentDir)

	_, err := c.readdir.UpdateOne(context.Background(), filter, bson.M{"$set": proto}, opts)
	if err != nil {
		return err
	}

	filter.Index.Unset()
	count, err := c.readdir.CountDocuments(context.Background(), filter)
	if err != nil {
		return err
	}

	if count == readDir.Total {
		return c.handleReaddirComplete(file, readDir)
	}

	return nil
}

func (c *consumer) handleReaddirComplete(file *File, readDir *events.ReadDir) error {
	filter := ReaddirPrototype{}
	filter.Readdir.Set(readDir.Readdir)

	cur, err := c.readdir.Find(context.Background(), filter)
	if err != nil {
		return err
	}

	var entries []Readdir
	cur.All(context.Background(), &entries)

	if len(entries) != int(readDir.Total) {
		c.log.Debug("readdir "+readDir.Readdir+" incomplete", "count", len(entries), "total", readDir.Total)
		return nil
	}

	var ids []primitive.ObjectID = make([]primitive.ObjectID, len(entries))
	for i, entry := range entries {
		ids[i] = entry.File
	}

	deleteFileFilter := bson.M{
		"parentDir": file.ParentDir,
		"_id":       bson.M{"$nin": ids},
	}

	cur, err = c.files.Find(context.Background(), deleteFileFilter)
	if err != nil {
		return err
	}

	for cur.Next(context.Background()) {
		var f File
		cur.Decode(&f)
		c.publishChange(&f, events.FileChangedEventDeleted)
	}

	res, err := c.files.DeleteMany(context.Background(), deleteFileFilter)
	if err != nil {
		return err
	}

	c.log.Debug("readdir "+readDir.Readdir+" complete", "total", readDir.Total, "deleted", res.DeletedCount)

	_, err = c.readdir.DeleteMany(context.Background(), filter)
	if err != nil {
		return err
	}

	return nil
}
