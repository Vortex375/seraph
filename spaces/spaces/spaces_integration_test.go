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

package spaces_test

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"testing"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/spf13/viper"
	"github.com/stretchr/testify/assert"
	"github.com/testcontainers/testcontainers-go"
	"go.mongodb.org/mongo-driver/mongo"
	"go.uber.org/fx/fxtest"
	"umbasa.net/seraph/entities"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/mongodb"
	"umbasa.net/seraph/spaces/spaces"
	"umbasa.net/seraph/tracing"
)

var natsServer *server.Server
var mongoContainer testcontainers.Container
var mongoUrl string
var migrations spaces.Migrations
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
	v.Set("mongo.db", "spaces_test")

	migrations, err = spaces.NewMigrations(v)
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

func getSpacesProvider(t *testing.T) (*spaces.SpacesProvider, *nats.Conn, *mongo.Database) {
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
	db := mongoClient.Database("spaces_test")

	res2, _ := spaces.New(spaces.Params{
		Nc:      nc,
		Logger:  logger,
		Tracing: tracing.NewNoopTracing(),
		Db:      db,
	})

	return res2.SpacesProvider, nc, db
}

func TestSpaceCrud(t *testing.T) {
	spacesProvider, nc, _ := getSpacesProvider(t)

	spacesProvider.Start()
	defer spacesProvider.Stop()

	// CREATE

	req := spaces.SpaceCrudRequest{
		Operation: "CREATE",
		Space:     entities.MakePrototype(&spaces.SpacePrototype{}),
	}

	providers := []spaces.SpaceFileProvider{
		{
			SpaceProviderId: "pippo",
			ProviderId:      "foo",
			Path:            "/",
		},
		{
			SpaceProviderId: "peppo",
			ProviderId:      "bar",
			Path:            "/test/path",
		},
	}

	req.Space.Title.Set("some title")
	req.Space.Description.Set("some description")
	req.Space.Users.Set([]string{"pino", "lino"})
	req.Space.FileProviders.Set(providers)

	res := spaces.SpaceCrudResponse{}
	err := messaging.Request(context.Background(), nc, spaces.SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.NotNil(t, res.Space)
	assert.Equal(t, 1, len(res.Space))
	assert.NotNil(t, res.Space[0].Id)
	assert.Equal(t, "some title", res.Space[0].Title)
	assert.Equal(t, "some description", res.Space[0].Description)
	assert.Equal(t, []string{"pino", "lino"}, res.Space[0].Users)
	assert.Equal(t, providers, res.Space[0].FileProviders)

	createdId := res.Space[0].Id

	// CREATE duplicate -> expect error

	req = spaces.SpaceCrudRequest{
		Operation: "CREATE",
		Space:     entities.MakePrototype(&spaces.SpacePrototype{}),
	}

	providers2 := []spaces.SpaceFileProvider{
		{
			SpaceProviderId: "pippo",
			ProviderId:      "baz",
			Path:            "/is/duplicate",
		},
	}

	req.Space.Title.Set("some other title")
	req.Space.Description.Set("some other description")
	req.Space.FileProviders.Set(providers2)

	err = messaging.Request(context.Background(), nc, spaces.SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.NotEqual(t, "", res.Error)

	// CREATE second

	req = spaces.SpaceCrudRequest{
		Operation: "CREATE",
		Space:     entities.MakePrototype(&spaces.SpacePrototype{}),
	}

	providers2 = []spaces.SpaceFileProvider{
		{
			SpaceProviderId: "pippolino",
			ProviderId:      "baz",
			Path:            "/not/duplicate",
		},
	}

	req.Space.Title.Set("some second title")
	req.Space.Description.Set("some second description")
	req.Space.Users.Set([]string{"mino", "tino"})
	req.Space.FileProviders.Set(providers2)

	err = messaging.Request(context.Background(), nc, spaces.SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.NotNil(t, res.Space)
	assert.Equal(t, 1, len(res.Space))
	assert.NotNil(t, res.Space[0].Id)
	assert.Equal(t, "some second title", res.Space[0].Title)
	assert.Equal(t, "some second description", res.Space[0].Description)
	assert.Equal(t, []string{"mino", "tino"}, res.Space[0].Users)
	assert.Equal(t, providers2, res.Space[0].FileProviders)

	createdId2 := res.Space[0].Id

	// UPDATE

	req = spaces.SpaceCrudRequest{
		Operation: "UPDATE",
		Space:     entities.MakePrototype(&spaces.SpacePrototype{}),
	}

	providers3 := []spaces.SpaceFileProvider{
		{
			SpaceProviderId: "pippo",
			ProviderId:      "foo2",
			Path:            "/",
		},
		{
			SpaceProviderId: "peppo",
			ProviderId:      "bar2",
			Path:            "/test/path",
		},
	}

	req.Space.Id.Set(createdId)
	req.Space.Title.Set("some other title")
	req.Space.Description.Set("some other description")
	req.Space.Users.Set([]string{"dino", "nino"})
	req.Space.FileProviders.Set(providers3)

	err = messaging.Request(context.Background(), nc, spaces.SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.NotNil(t, res.Space)
	assert.Equal(t, createdId, res.Space[0].Id)
	assert.Equal(t, "some other title", res.Space[0].Title)
	assert.Equal(t, "some other description", res.Space[0].Description)
	assert.Equal(t, []string{"dino", "nino"}, res.Space[0].Users)
	assert.Equal(t, providers3, res.Space[0].FileProviders)

	// READ - all

	req = spaces.SpaceCrudRequest{
		Operation: "READ",
		Space:     entities.MakePrototype(&spaces.SpacePrototype{}),
	}

	err = messaging.Request(context.Background(), nc, spaces.SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.NotNil(t, res.Space)
	assert.Equal(t, 2, len(res.Space))

	// READ - by id

	req = spaces.SpaceCrudRequest{
		Operation: "READ",
		Space:     entities.MakePrototype(&spaces.SpacePrototype{}),
	}
	req.Space.Id.Set(createdId2)

	err = messaging.Request(context.Background(), nc, spaces.SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.NotNil(t, res.Space)
	assert.Equal(t, 1, len(res.Space))
	assert.Equal(t, createdId2, res.Space[0].Id)

	// READ - by user

	req = spaces.SpaceCrudRequest{
		Operation: "READ",
		Space:     entities.MakePrototype(&spaces.SpacePrototype{}),
	}
	req.Space.Users.Set([]string{"nino"})

	err = messaging.Request(context.Background(), nc, spaces.SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.NotNil(t, res.Space)
	assert.Equal(t, 1, len(res.Space))
	assert.Equal(t, createdId, res.Space[0].Id)

	// READ - by user 2

	req = spaces.SpaceCrudRequest{
		Operation: "READ",
		Space:     entities.MakePrototype(&spaces.SpacePrototype{}),
	}
	req.Space.Users.Set([]string{"tino"})

	err = messaging.Request(context.Background(), nc, spaces.SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.NotNil(t, res.Space)
	assert.Equal(t, 1, len(res.Space))
	assert.Equal(t, createdId2, res.Space[0].Id)

	// READ - by user not exists

	req = spaces.SpaceCrudRequest{
		Operation: "READ",
		Space:     entities.MakePrototype(&spaces.SpacePrototype{}),
	}
	req.Space.Users.Set([]string{"pippo"})

	err = messaging.Request(context.Background(), nc, spaces.SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.NotNil(t, res.Space)
	assert.Equal(t, 0, len(res.Space))

	// DELETE

	req = spaces.SpaceCrudRequest{
		Operation: "DELETE",
		Space:     entities.MakePrototype(&spaces.SpacePrototype{}),
	}
	req.Space.Id.Set(createdId)

	err = messaging.Request(context.Background(), nc, spaces.SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)

	// READ again -> expect not found
	req = spaces.SpaceCrudRequest{
		Operation: "READ",
		Space:     entities.MakePrototype(&spaces.SpacePrototype{}),
	}
	req.Space.Users.Set([]string{"nino"})

	err = messaging.Request(context.Background(), nc, spaces.SpaceCrudTopic, messaging.Json(&req), messaging.Json(&res))

	assert.Nil(t, err)
	assert.Equal(t, "", res.Error)
	assert.NotNil(t, res.Space)
	assert.Equal(t, 0, len(res.Space))

}

func TestSpaceResolve(t *testing.T) {
	spacesProvider, nc, _ := getSpacesProvider(t)

	spacesProvider.Start()
	defer spacesProvider.Stop()

	// CREATE

	req := spaces.SpaceCrudRequest{
		Operation: "CREATE",
		Space:     entities.MakePrototype(&spaces.SpacePrototype{}),
	}

	providers := []spaces.SpaceFileProvider{
		{
			SpaceProviderId: "pippo",
			ProviderId:      "foo",
			Path:            "/",
		},
		{
			SpaceProviderId: "peppo",
			ProviderId:      "bar",
			Path:            "/test/path",
			ReadOnly:        true,
		},
	}

	req.Space.Title.Set("some title")
	req.Space.Description.Set("some description")
	req.Space.Users.Set([]string{"pino", "lino"})
	req.Space.FileProviders.Set(providers)

	err := messaging.RequestVoid(context.Background(), nc, spaces.SpaceCrudTopic, messaging.Json(&req))
	if err != nil {
		t.Fatal(err)
	}

	// CREATE 2

	req = spaces.SpaceCrudRequest{
		Operation: "CREATE",
		Space:     entities.MakePrototype(&spaces.SpacePrototype{}),
	}

	providers = []spaces.SpaceFileProvider{
		{
			SpaceProviderId: "pippolino",
			ProviderId:      "baz",
			Path:            "/",
		},
	}

	req.Space.Title.Set("some title")
	req.Space.Description.Set("some description")
	req.Space.Users.Set([]string{"dino"})
	req.Space.FileProviders.Set(providers)

	err = messaging.RequestVoid(context.Background(), nc, spaces.SpaceCrudTopic, messaging.Json(&req))
	if err != nil {
		t.Fatal(err)
	}

	// resolve empty path

	resolveReq := spaces.SpaceResolveRequest{
		UserId:          "pino",
		SpaceProviderId: "pippo",
	}

	res := spaces.SpaceResolveResponse{}
	err = messaging.Request(context.Background(), nc, spaces.SpaceResolveTopic, messaging.Json(&resolveReq), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.Equal(t, "foo", res.ProviderId)
	assert.Equal(t, "/", res.Path)

	resolveReq = spaces.SpaceResolveRequest{
		UserId:          "pino",
		SpaceProviderId: "peppo",
	}

	res = spaces.SpaceResolveResponse{}
	err = messaging.Request(context.Background(), nc, spaces.SpaceResolveTopic, messaging.Json(&resolveReq), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.Equal(t, "bar", res.ProviderId)
	assert.Equal(t, "/test/path", res.Path)
	assert.Equal(t, true, res.ReadOnly)

	// resolve - no access

	resolveReq = spaces.SpaceResolveRequest{
		UserId:          "pino",
		SpaceProviderId: "pippolino",
	}

	res = spaces.SpaceResolveResponse{}
	err = messaging.Request(context.Background(), nc, spaces.SpaceResolveTopic, messaging.Json(&resolveReq), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.Equal(t, "", res.ProviderId)
	assert.Equal(t, "", res.Path)
}
