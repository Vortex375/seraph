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

package gallery_test

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/spf13/viper"
	"github.com/stretchr/testify/assert"
	"github.com/testcontainers/testcontainers-go"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.uber.org/fx/fxtest"
	"umbasa.net/seraph/gallery/gallery"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/mongodb"
	"umbasa.net/seraph/spaces/spaces"
	"umbasa.net/seraph/tracing"
)

var natsServer *server.Server
var mongoContainer testcontainers.Container
var mongoUrl string
var migrations gallery.Migrations
var v *viper.Viper

func TestMain(m *testing.M) {
	setup()
	code := m.Run()
	shutdown()
	os.Exit(code)
}

func setup() {
	opts := &server.Options{}
	var err error
	natsServer, err = server.NewServer(opts)
	if err != nil {
		panic(err)
	}

	natsServer.Start()
	if !natsServer.ReadyForConnections(10 * time.Second) {
		panic("embedded NATS server did not become ready")
	}

	req := testcontainers.ContainerRequest{
		Image:        "mongo:8",
		ExposedPorts: []string{"27017/tcp"},
	}

	mongoContainer, err = testcontainers.GenericContainer(context.Background(), testcontainers.GenericContainerRequest{
		ContainerRequest: req,
		Started:          true,
	})
	if err != nil {
		panic(err)
	}

	endpoint, err := mongoContainer.Endpoint(context.Background(), "")
	if err != nil {
		panic(err)
	}

	mongoUrl = fmt.Sprintf("mongodb://%s/", endpoint)

	v = viper.New()
	v.Set("mongo.url", mongoUrl)
	v.Set("mongo.db", "gallery_test")

	migrations, err = gallery.NewMigrations(v)
	if err != nil {
		panic(err)
	}
}

func shutdown() {
	if natsServer != nil {
		natsServer.Shutdown()
		natsServer = nil
	}
	if mongoContainer != nil {
		testcontainers.TerminateContainer(mongoContainer)
	}
}

func getGalleryProvider(t *testing.T) (*gallery.GalleryProvider, *nats.Conn, *mongo.Database) {
	nc, err := nats.Connect(natsServer.ClientURL())
	if err != nil {
		t.Fatal(err)
	}

	res, err := mongodb.NewClient(mongodb.ClientParams{
		Viper:   v,
		Tracing: tracing.NewNoopTracing(),
		Lc:      fxtest.NewLifecycle(t),
	})
	if err != nil {
		t.Fatal(err)
	}
	mongoClient := res.Client

	logger := logging.New(logging.Params{})
	logger.SetLevel(slog.LevelDebug)
	db := mongoClient.Database("gallery_test")

	res2, err := gallery.New(gallery.Params{
		Nc:      nc,
		Logger:  logger,
		Tracing: tracing.NewNoopTracing(),
		Db:      db,
		Mig:     migrations,
	})
	if err != nil {
		t.Fatal(err)
	}

	return res2.GalleryProvider, nc, db
}

// startGalleryProvider brings up the provider together with a stub `spaces`
// service. accessible lists the spaceProviderIds the stub resolves for a given
// user; anything else resolves empty, which is how `spaces` reports "no access".
func startGalleryProvider(t *testing.T, accessible map[string][]string) (*nats.Conn, *mongo.Database) {
	t.Helper()

	provider, nc, db := getGalleryProvider(t)

	if err := provider.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		provider.Stop()
		nc.Close()
	})

	sub, err := nc.Subscribe(spaces.SpaceResolveTopic, func(msg *nats.Msg) {
		req := spaces.SpaceResolveRequest{}
		json.Unmarshal(msg.Data, &req)

		resp := spaces.SpaceResolveResponse{}
		for _, spaceProviderId := range accessible[req.UserId] {
			if spaceProviderId == req.SpaceProviderId {
				resp.ProviderId = "physical-" + spaceProviderId
				resp.Path = "/mounted/" + spaceProviderId
				break
			}
		}

		data, _ := json.Marshal(&resp)
		msg.Respond(data)
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		sub.Unsubscribe()
	})

	if err := nc.Flush(); err != nil {
		t.Fatal(err)
	}

	return nc, db
}

func crud(t *testing.T, nc *nats.Conn, req *gallery.GallerySourceFolderCrudRequest) *gallery.GallerySourceFolderCrudResponse {
	t.Helper()

	res := gallery.GallerySourceFolderCrudResponse{}
	err := messaging.Request(context.Background(), nc, gallery.GallerySourceFolderCrudTopic, messaging.Json(req), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}
	return &res
}

func clearSourceFolders(t *testing.T, db *mongo.Database) {
	t.Helper()
	if _, err := db.Collection("gallerySourceFolders").DeleteMany(context.Background(), bson.M{}); err != nil {
		t.Fatal(err)
	}
}

func TestListAddRemoveSourceFolders(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)

	// LIST is empty to begin with

	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationList,
		UserId:    "pino",
	})

	assert.Equal(t, "", res.Error)
	assert.Equal(t, 0, len(res.SourceFolder))

	// ADD

	res = crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})

	assert.Equal(t, "", res.Error)
	assert.Equal(t, 1, len(res.SourceFolder))
	assert.Equal(t, "pino", res.SourceFolder[0].UserId)
	// stored in Space terms, exactly as picked
	assert.Equal(t, "photos", res.SourceFolder[0].SpaceProviderId)
	assert.Equal(t, "/holidays", res.SourceFolder[0].Path)
	assert.False(t, res.SourceFolder[0].Id.IsZero())

	addedId := res.SourceFolder[0].Id

	// LIST now returns the folder

	res = crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationList,
		UserId:    "pino",
	})

	assert.Equal(t, "", res.Error)
	assert.Equal(t, 1, len(res.SourceFolder))
	assert.Equal(t, addedId, res.SourceFolder[0].Id)

	// REMOVE

	res = crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationRemove,
		UserId:    "pino",
		Id:        addedId.Hex(),
	})

	assert.Equal(t, "", res.Error)
	assert.Equal(t, 1, len(res.SourceFolder))
	assert.Equal(t, addedId, res.SourceFolder[0].Id)

	// and it is gone

	res = crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationList,
		UserId:    "pino",
	})

	assert.Equal(t, "", res.Error)
	assert.Equal(t, 0, len(res.SourceFolder))
}

func TestAddSourceFolderIsIdempotent(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)

	req := gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	}

	first := crud(t, nc, &req)
	assert.Equal(t, "", first.Error)
	assert.Equal(t, 1, len(first.SourceFolder))

	second := crud(t, nc, &req)
	assert.Equal(t, "", second.Error)
	assert.Equal(t, 1, len(second.SourceFolder))

	// the same document, not a second one
	assert.Equal(t, first.SourceFolder[0].Id, second.SourceFolder[0].Id)

	// a trailing slash is the same folder
	withSlash := req
	withSlash.Path = "/holidays/"
	third := crud(t, nc, &withSlash)
	assert.Equal(t, "", third.Error)
	assert.Equal(t, first.SourceFolder[0].Id, third.SourceFolder[0].Id)

	list := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationList,
		UserId:    "pino",
	})
	assert.Equal(t, "", list.Error)
	assert.Equal(t, 1, len(list.SourceFolder))
}

func TestAddSourceFolderWithoutAccessIsRefused(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)

	// lino has no spaces at all
	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "lino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})

	assert.NotEqual(t, "", res.Error)
	assert.Equal(t, 0, len(res.SourceFolder))

	// and nothing was stored
	list := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationList,
		UserId:    "lino",
	})
	assert.Equal(t, "", list.Error)
	assert.Equal(t, 0, len(list.SourceFolder))

	// a space the user cannot see is refused just the same
	res = crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "someone-elses-space",
		Path:            "/holidays",
	})

	assert.NotEqual(t, "", res.Error)
	assert.Equal(t, 0, len(res.SourceFolder))
}

func TestSourceFoldersAreScopedPerUser(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
		"lino": {"photos"},
	})
	clearSourceFolders(t, db)

	pino := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/pino",
	})
	assert.Equal(t, "", pino.Error)

	lino := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "lino",
		SpaceProviderId: "photos",
		Path:            "/lino",
	})
	assert.Equal(t, "", lino.Error)

	// each user sees only their own
	pinoList := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationList,
		UserId:    "pino",
	})
	assert.Equal(t, "", pinoList.Error)
	assert.Equal(t, 1, len(pinoList.SourceFolder))
	assert.Equal(t, "/pino", pinoList.SourceFolder[0].Path)

	linoList := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationList,
		UserId:    "lino",
	})
	assert.Equal(t, "", linoList.Error)
	assert.Equal(t, 1, len(linoList.SourceFolder))
	assert.Equal(t, "/lino", linoList.SourceFolder[0].Path)

	// the same folder configured by two users are two independent documents
	assert.NotEqual(t, pinoList.SourceFolder[0].Id, linoList.SourceFolder[0].Id)

	// and one user cannot remove another user's folder by guessing its id
	stolen := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationRemove,
		UserId:    "pino",
		Id:        linoList.SourceFolder[0].Id.Hex(),
	})
	assert.NotEqual(t, "", stolen.Error)

	linoList = crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationList,
		UserId:    "lino",
	})
	assert.Equal(t, 1, len(linoList.SourceFolder))
}

// TestRemoveTouchesNoFileProvider asserts that removing a Gallery Source Folder
// is a configuration change only: it deletes the configuration document and
// sends no message to any other service.
func TestRemoveTouchesNoFileProvider(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)

	// watch every seraph subject except our own CRUD topic
	observed := make(chan string, 16)
	watch, err := nc.Subscribe("seraph.>", func(msg *nats.Msg) {
		if msg.Subject != gallery.GallerySourceFolderCrudTopic {
			observed <- msg.Subject
		}
	})
	if err != nil {
		t.Fatal(err)
	}
	defer watch.Unsubscribe()

	added := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "/holidays",
	})
	assert.Equal(t, "", added.Error)

	// drain what ADD legitimately caused (the space resolve)
	if err := nc.Flush(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	for len(observed) > 0 {
		<-observed
	}

	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationRemove,
		UserId:    "pino",
		Id:        added.SourceFolder[0].Id.Hex(),
	})
	assert.Equal(t, "", res.Error)

	if err := nc.Flush(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)

	subjects := make([]string, 0)
	for len(observed) > 0 {
		subjects = append(subjects, <-observed)
	}
	assert.Empty(t, subjects, "REMOVE must not contact any other service")
}

func TestInvalidRequests(t *testing.T) {
	nc, db := startGalleryProvider(t, map[string][]string{
		"pino": {"photos"},
	})
	clearSourceFolders(t, db)

	// missing userId
	res := crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationList,
	})
	assert.NotEqual(t, "", res.Error)

	// unknown operation
	res = crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: "FROBNICATE",
		UserId:    "pino",
	})
	assert.NotEqual(t, "", res.Error)

	// ADD without spaceProviderId
	res = crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationAdd,
		UserId:    "pino",
		Path:      "/holidays",
	})
	assert.NotEqual(t, "", res.Error)

	// ADD with a relative path
	res = crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation:       gallery.GallerySourceFolderOperationAdd,
		UserId:          "pino",
		SpaceProviderId: "photos",
		Path:            "holidays",
	})
	assert.NotEqual(t, "", res.Error)

	// REMOVE without id
	res = crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationRemove,
		UserId:    "pino",
	})
	assert.NotEqual(t, "", res.Error)

	// REMOVE with a malformed id
	res = crud(t, nc, &gallery.GallerySourceFolderCrudRequest{
		Operation: gallery.GallerySourceFolderOperationRemove,
		UserId:    "pino",
		Id:        "not-an-object-id",
	})
	assert.NotEqual(t, "", res.Error)
}
