package fileindexer

import (
	"context"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"mime"
	"os"
	"path"
	"regexp"
	"strings"
	"time"

	"github.com/boz/go-throttle"
	"github.com/gabriel-vasile/mimetype"
	"github.com/google/uuid"
	"github.com/kalafut/imohash"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/spf13/viper"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/bson/primitive"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"go.uber.org/fx"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/util"
)

type Consumer interface {
	Start() error
	Stop()
}

type consumer struct {
	logger         *logging.Logger
	log            *slog.Logger
	nc             *nats.Conn
	js             jetstream.JetStream
	fileInfoStream jetstream.Stream
	consumer       jetstream.Consumer
	kv             jetstream.KeyValue

	limiter          util.Limiter
	progressThrottle throttle.Throttle

	ctx    context.Context
	cancel context.CancelFunc

	files   *mongo.Collection
	readdir *mongo.Collection
}

type Params struct {
	fx.In

	Nc     *nats.Conn
	Js     jetstream.JetStream
	Db     *mongo.Database
	Logger *logging.Logger
	Viper  *viper.Viper
	Mig    Migrations
}

var searchWordsRegex = regexp.MustCompile("\\W|_")

func NewConsumer(p Params) (Consumer, error) {
	log := p.Logger.GetLogger("fileindexer")

	// create stream for FileChangedEvent - we are producer for these

	log.Debug("create " + events.FileChangedStream)
	_, err := p.Js.CreateOrUpdateStream(context.Background(), jetstream.StreamConfig{
		Name:     events.FileChangedStream,
		Subjects: []string{events.FileChangedTopic},
	})
	if err != nil {
		return nil, err
	}

	// create stream for FileInfoEvent - we consume these

	log.Debug("create " + events.FileInfoStream)
	stream, err := p.Js.CreateOrUpdateStream(context.Background(), jetstream.StreamConfig{
		Name:     events.FileInfoStream,
		Subjects: []string{events.FileProviderFileInfoTopic},
	})
	if err != nil {
		return nil, err
	}

	kv, err := p.Js.CreateOrUpdateKeyValue(context.Background(), jetstream.KeyValueConfig{
		Bucket: "SERAPH_FILE_INDEXER",
	})
	kv.Create(context.Background(), "lastSeq", make([]byte, 8))

	ctx, cancel := context.WithCancel(context.Background())

	c, _ := stream.CreateOrUpdateConsumer(ctx, jetstream.ConsumerConfig{
		Durable: "SERAPH_FILE_INDEXER",
	})

	files := p.Db.Collection("files")
	readdir := p.Db.Collection("readdir")

	limiter := util.NewLimiter(p.Viper.GetInt("fileindexer.parallel"))
	progressThrottle := throttle.NewThrottle(2*time.Second, true)

	cons := consumer{
		logger:         p.Logger,
		log:            log,
		nc:             p.Nc,
		js:             p.Js,
		fileInfoStream: stream,
		consumer:       c,
		kv:             kv,

		limiter:          limiter,
		progressThrottle: progressThrottle,

		files:   files,
		readdir: readdir,
		ctx:     ctx,
		cancel:  cancel,
	}

	return &cons, nil
}

func (c *consumer) Start() error {
	iter, err := c.consumer.Messages()
	if err != nil {
		return err
	}

	go func() {
		for {
			msg, err := iter.Next()
			if errors.Is(err, jetstream.ErrMsgIteratorClosed) {
				return
			}
			if err != nil {
				c.log.Error("consumer error", "error", err)
				return
			}
			if !c.limiter.Begin(c.ctx) {
				return
			}
			go c.handleMessage(msg)
		}
	}()

	go func() {
		for c.progressThrottle.Next() {
			c.updateProgress()
		}
	}()

	return nil
}

func (c *consumer) Stop() {
	c.cancel()
	c.limiter.Join()
	c.progressThrottle.Stop()
}

func (c *consumer) handleMessage(msg jetstream.Msg) {
	defer c.limiter.End()

	metadata, err := msg.Metadata()
	if err != nil {
		c.log.Error("failed to read message metadata", "error", err)
		return
	}

	fileInfoEvent := events.FileInfoEvent{}

	err = fileInfoEvent.Unmarshal(msg.Data())
	if err != nil {
		c.log.Error("failed to deserialize message", "error", err)
		return
	}

	if !strings.HasPrefix(fileInfoEvent.Path, "/") {
		c.log.Error("error processing FileInfoEvent: path is not absolute", "event", fileInfoEvent)
		msg.TermWithReason("path is not absolute")
		return
	}

	cleanPath := path.Clean(fileInfoEvent.Path)
	file := FilePrototype{}
	file.ProviderId.Set(fileInfoEvent.ProviderID)
	file.Path.Set(cleanPath)
	file.SearchWords.Set(strings.TrimSpace(searchWordsRegex.ReplaceAllString(cleanPath, " ")))
	file.IsDir.Set(fileInfoEvent.IsDir)
	if fileInfoEvent.ModTime != 0 || fileInfoEvent.Mode != 0 || fileInfoEvent.Size != 0 {
		file.ModTime.Set(fileInfoEvent.ModTime)
		file.Mode.Set(fileInfoEvent.Mode)
		file.Size.Set(fileInfoEvent.Size)
	}
	if !fileInfoEvent.IsDir {
		file.Pending.Set(true)
	}

	newFile, change, err := c.upsertFile(&file)

	if err != nil {
		c.log.Error("error processing FileInfoEvent", "error", err, "event", fileInfoEvent)
		return
	}

	if change != "" {
		err = c.handleChangedFile(newFile, change)
		if err != nil {
			c.log.Error("error processing changed file", "error", err, "event", fileInfoEvent)
			return
		}
	} else {
		err = c.handleUnchangedFile(newFile)
		if err != nil {
			c.log.Error("error processing unchanged file", "error", err, "event", fileInfoEvent)
			return
		}
	}

	if fileInfoEvent.Readdir != nil {
		c.handleReaddir(newFile, fileInfoEvent.Readdir)
	}

	c.log.Debug("successfully processed file event", "event", fileInfoEvent)
	msg.Ack()

	c.updateLastSeq(metadata.Sequence.Stream)
	c.progressThrottle.Trigger()
}

func (c *consumer) updateLastSeq(newValue uint64) {
	for {
		current, err := c.kv.Get(c.ctx, "lastSeq")
		if err != nil {
			c.log.Error("error while updating progress", "error", err)
			return
		}
		currentValue := binary.LittleEndian.Uint64(current.Value())
		if newValue <= currentValue {
			return
		}
		newVal := make([]byte, 8)
		binary.LittleEndian.PutUint64(newVal, newValue)
		_, err = c.kv.Update(c.ctx, "lastSeq", newVal, current.Revision())
		if err == nil {
			return
		}
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

		if oldFile.Pending {
			// consumer was previously interrupted while processing changes for the file
			change = events.FileChangedEventChanged
		} else if oldFile.ModTime != newFile.ModTime ||
			oldFile.Size != newFile.Size ||
			oldFile.Mode != newFile.Mode {
			// file was modified
			change = events.FileChangedEventChanged
		}
	}
	return
}

func (c *consumer) handleChangedFile(file *File, change string) error {
	mimeTyp := c.detectAndUpdateMime(file)
	imoHash := c.calculateAndUpdateImoHash(file)

	filter := FilePrototype{}
	filter.Id.Set(file.Id)

	proto := FilePrototype{}
	proto.Mime.Set(mimeTyp)
	proto.ImoHash.Set(imoHash)
	proto.Pending.Set(false)

	_, err := c.files.UpdateOne(context.TODO(), filter, bson.M{"$set": proto})
	if err != nil {
		c.log.Error("error persisting mimeType and hash", "error", err, "file", file)
		return err
	}

	err = c.publishChange(file, change)
	if err != nil {
		c.log.Error("error publishing FileChangedEvent", "error", err, "file", file)
		return err
	}

	return nil
}

func (c *consumer) detectAndUpdateMime(file *File) string {
	if file.IsDir {
		return ""
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
			return ""
		}
		defer inFile.Close()
		mimeType, err := mimetype.DetectReader(inFile)
		if err != nil {
			c.log.Error("Error while detecting mime type", "path", file.Path, "error", err)
			return ""
		}
		typ = mimeType.String()
	}

	c.log.Debug("Identified mime type", "path", file.Path, "mime", typ)

	file.Mime = typ

	return typ
}

func (c *consumer) calculateAndUpdateImoHash(file *File) string {
	if file.IsDir {
		return ""
	}

	client := fileprovider.NewFileProviderClient(file.ProviderId, c.nc, c.logger)
	defer client.Close()
	inFile, err := client.OpenFile(context.TODO(), file.Path, os.O_RDONLY, 0)
	if err != nil {
		c.log.Error("Error while opening file for imo hash calculation", "path", file.Path, "error", err)
		return ""
	}
	defer inFile.Close()

	readerAt := &util.ReaderAt{ReadSeeker: inFile}

	hash, err := imohash.SumSectionReader(io.NewSectionReader(readerAt, 0, file.Size))
	if err != nil {
		c.log.Error("Error while calculating imo hash", "path", file.Path, "error", err)
		return ""
	}

	hashStr := hex.EncodeToString(hash[:])

	c.log.Debug("Calculated imo hash", "path", file.Path, "hash", hashStr)

	file.ImoHash = hashStr

	return hashStr
}

func (c *consumer) handleUnchangedFile(file *File) error {
	filter := FilePrototype{}
	filter.Id.Set(file.Id)

	proto := FilePrototype{}
	proto.Pending.Set(false)

	_, err := c.files.UpdateOne(context.TODO(), filter, bson.M{"$set": proto})
	return err
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

func (c *consumer) updateProgress() {
	info, err := c.fileInfoStream.Info(c.ctx)
	if err != nil {
		c.log.Error("error updating index progress", "error", err)
		return
	}

	lastSeq, err := c.kv.Get(c.ctx, "lastSeq")
	if err != nil {
		c.log.Error("error updating index progress", "error", err)
		return
	}

	remaining := info.State.LastSeq - binary.LittleEndian.Uint64(lastSeq.Value())

	if remaining > 0 {
		c.log.Info(fmt.Sprintf("Index progress: %d remaining", remaining), "remaining", remaining)
	} else {
		c.log.Info("Indexing complete.", "remaining", remaining)
	}

	ev := events.JobEvent{
		Event: events.Event{
			ID:      uuid.NewString(),
			Version: 1,
		},
		Key:           "SERAPH_FILE_INDEXER",
		Description:   "Indexing files",
		StatusMessage: fmt.Sprintf("Index progress: %d remaining", remaining),
	}
	data, _ := ev.Marshal()
	topic := fmt.Sprintf(events.FileChangedTopicPattern, "SERAPH_FILE_INDEXER")
	c.nc.Publish(topic, data)
}
