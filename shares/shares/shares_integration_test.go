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

package shares_test

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
	"umbasa.net/seraph/shares/shares"
	"umbasa.net/seraph/spaces/spaces"
	"umbasa.net/seraph/tracing"
)

var natsServer *server.Server
var mongoContainer testcontainers.Container
var mongoUrl string
var sharesMigrations shares.Migrations
var spacesMigrations spaces.Migrations

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

	v := viper.New()
	v.Set("mongo.url", mongoUrl)
	v.Set("mongo.db", "shares_test")

	sharesMigrations, err = shares.NewMigrations(v)
	if err != nil {
		panic(err)
	}

	v.Set("mongo.db", "spaces_test")
	spacesMigrations, err = spaces.NewMigrations(v)
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

func getSharesProvider(t *testing.T) (*shares.SharesProvider, *nats.Conn, *mongo.Database) {
	nc, err := nats.Connect(natsServer.ClientURL())
	if err != nil {
		t.Fatal(err)
	}

	v := viper.New()
	v.Set("mongo.url", mongoUrl)
	v.Set("mongo.db", "shares_test")

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
	db := mongoClient.Database("shares_test")

	res2, _ := shares.New(shares.Params{
		Nc:      nc,
		Logger:  logger,
		Tracing: tracing.NewNoopTracing(),
		Db:      db,
		Mig:     sharesMigrations,
	})

	return res2.SharesProvider, nc, db
}

func getSpacesProvider(t *testing.T) (*spaces.SpacesProvider, *nats.Conn, *mongo.Database) {
	nc, err := nats.Connect(natsServer.ClientURL())
	if err != nil {
		t.Fatal(err)
	}

	v := viper.New()
	v.Set("mongo.url", mongoUrl)
	v.Set("mongo.db", "spaces_test")

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
		Mig:     spacesMigrations,
	})

	return res2.SpacesProvider, nc, db
}

func TestShareCrud(t *testing.T) {
	sharesProvider, nc, _ := getSharesProvider(t)

	sharesProvider.Start()
	defer sharesProvider.Stop()

	// CREATE

	req := shares.ShareCrudRequest{
		Operation: "CREATE",
		Share:     entities.MakePrototype(&shares.SharePrototype{}),
	}

	req.Share.ShareId.Set("test")
	req.Share.Owner.Set("user")
	req.Share.Title.Set("some title")
	req.Share.Description.Set("some description")
	req.Share.ProviderId.Set("foo")
	req.Share.Path.Set("/bar/baz")
	req.Share.Recursive.Set(true)
	req.Share.IsDir.Set(true)

	res := shares.ShareCrudResponse{}
	err := messaging.Request(context.Background(), nc, shares.ShareCrudTopic, messaging.Json(&req), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.NotNil(t, res.Share)
	assert.Equal(t, 1, len(res.Share))
	assert.Equal(t, "test", res.Share[0].ShareId)
	assert.Equal(t, "user", res.Share[0].Owner)
	assert.Equal(t, "some title", res.Share[0].Title)
	assert.Equal(t, "some description", res.Share[0].Description)
	assert.Equal(t, "foo", res.Share[0].ProviderId)
	assert.Equal(t, "/bar/baz", res.Share[0].Path)
	assert.Equal(t, true, res.Share[0].Recursive)
	assert.Equal(t, true, res.Share[0].IsDir)

	// CREATE duplicate -> expect error

	req = shares.ShareCrudRequest{
		Operation: "CREATE",
		Share:     entities.MakePrototype(&shares.SharePrototype{}),
	}

	req.Share.ShareId.Set("test")
	req.Share.Owner.Set("user")
	req.Share.Title.Set("some title")
	req.Share.Description.Set("some description")
	req.Share.ProviderId.Set("foo")
	req.Share.Path.Set("/bar/baz")
	req.Share.Recursive.Set(true)
	req.Share.IsDir.Set(true)

	err = messaging.Request(context.Background(), nc, shares.ShareCrudTopic, messaging.Json(&req), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.NotEqual(t, "", res.Error)

	// UPDATE

	req = shares.ShareCrudRequest{
		Operation: "UPDATE",
		Share:     entities.MakePrototype(&shares.SharePrototype{}),
	}

	req.Share.ShareId.Set("test")
	req.Share.Title.Set("some other title")
	req.Share.Description.Set("some other description")

	err = messaging.Request(context.Background(), nc, shares.ShareCrudTopic, messaging.Json(&req), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.NotNil(t, res.Share)
	assert.Equal(t, 1, len(res.Share))
	assert.Equal(t, "test", res.Share[0].ShareId)
	assert.Equal(t, "user", res.Share[0].Owner)
	assert.Equal(t, "some other title", res.Share[0].Title)
	assert.Equal(t, "some other description", res.Share[0].Description)
	assert.Equal(t, "foo", res.Share[0].ProviderId)
	assert.Equal(t, "/bar/baz", res.Share[0].Path)
	assert.Equal(t, true, res.Share[0].Recursive)
	assert.Equal(t, true, res.Share[0].IsDir)

	// READ

	req = shares.ShareCrudRequest{
		Operation: "READ",
		Share:     entities.MakePrototype(&shares.SharePrototype{}),
	}
	req.Share.ShareId.Set("test")

	err = messaging.Request(context.Background(), nc, shares.ShareCrudTopic, messaging.Json(&req), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.NotNil(t, res.Share)
	assert.Equal(t, 1, len(res.Share))
	assert.Equal(t, "test", res.Share[0].ShareId)
	assert.Equal(t, "user", res.Share[0].Owner)
	assert.Equal(t, "some other title", res.Share[0].Title)
	assert.Equal(t, "some other description", res.Share[0].Description)
	assert.Equal(t, "foo", res.Share[0].ProviderId)
	assert.Equal(t, "/bar/baz", res.Share[0].Path)
	assert.Equal(t, true, res.Share[0].Recursive)
	assert.Equal(t, true, res.Share[0].IsDir)

	// DELETE

	req = shares.ShareCrudRequest{
		Operation: "DELETE",
		Share:     entities.MakePrototype(&shares.SharePrototype{}),
	}
	req.Share.ShareId.Set("test")

	err = messaging.Request(context.Background(), nc, shares.ShareCrudTopic, messaging.Json(&req), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)

	// READ again -> expect not found
	req = shares.ShareCrudRequest{
		Operation: "READ",
		Share:     entities.MakePrototype(&shares.SharePrototype{}),
	}
	req.Share.ShareId.Set("test")

	err = messaging.Request(context.Background(), nc, shares.ShareCrudTopic, messaging.Json(&req), messaging.Json(&res))

	assert.Equal(t, "", res.Error)
	assert.NotNil(t, res.Share)
	assert.Equal(t, 0, len(res.Share))
}

func TestShareResolve(t *testing.T) {
	sharesProvider, nc, _ := getSharesProvider(t)

	sharesProvider.Start()
	defer sharesProvider.Stop()

	spacesProvider, nc, _ := getSpacesProvider(t)

	spacesProvider.Start()
	defer spacesProvider.Stop()

	// CREATE space
	spaceReq := spaces.SpaceCrudRequest{
		Operation: "CREATE",
		Space:     entities.MakePrototype(&spaces.SpacePrototype{}),
	}
	spaceReq.Space.Users.Set([]string{"user"})
	spaceReq.Space.FileProviders.Set([]spaces.SpaceFileProvider{
		{
			SpaceProviderId: "foo",
			ProviderId:      "foo-resolved",
			Path:            "/",
			ReadOnly:        false,
		},
		{
			SpaceProviderId: "foo-with-path",
			ProviderId:      "foo-resolved",
			Path:            "/space/path",
			ReadOnly:        false,
		},
		{
			SpaceProviderId: "foo-read-only",
			ProviderId:      "foo-resolved",
			Path:            "/",
			ReadOnly:        true,
		},
	})
	err := messaging.RequestVoid(context.Background(), nc, string(spaces.SpaceCrudTopic), messaging.Json(&spaceReq))
	if err != nil {
		t.Fatal(err)
	}

	// CREATE

	req := shares.ShareCrudRequest{
		Operation: "CREATE",
		Share:     entities.MakePrototype(&shares.SharePrototype{}),
	}
	req.Share.ShareId.Set("test")
	req.Share.Owner.Set("user")
	req.Share.ProviderId.Set("foo")
	req.Share.Path.Set("/bar/baz")
	req.Share.Recursive.Set(false)
	req.Share.IsDir.Set(true)
	req.Share.ReadOnly.Set(false)

	err = messaging.RequestVoid(context.Background(), nc, shares.ShareCrudTopic, messaging.Json(&req))
	if err != nil {
		t.Fatal(err)
	}

	// CREATE - with-space-path

	req = shares.ShareCrudRequest{
		Operation: "CREATE",
		Share:     entities.MakePrototype(&shares.SharePrototype{}),
	}
	req.Share.ShareId.Set("test-space-with-path")
	req.Share.Owner.Set("user")
	req.Share.ProviderId.Set("foo-with-path")
	req.Share.Path.Set("/bar/baz")
	req.Share.Recursive.Set(true)
	req.Share.IsDir.Set(true)
	req.Share.ReadOnly.Set(false)

	err = messaging.RequestVoid(context.Background(), nc, shares.ShareCrudTopic, messaging.Json(&req))
	if err != nil {
		t.Fatal(err)
	}

	// CREATE - readonly

	req = shares.ShareCrudRequest{
		Operation: "CREATE",
		Share:     entities.MakePrototype(&shares.SharePrototype{}),
	}
	req.Share.ShareId.Set("test-read-only")
	req.Share.Owner.Set("user")
	req.Share.ProviderId.Set("foo")
	req.Share.Path.Set("/bar/baz")
	req.Share.Recursive.Set(true)
	req.Share.IsDir.Set(true)
	req.Share.ReadOnly.Set(true)

	err = messaging.RequestVoid(context.Background(), nc, shares.ShareCrudTopic, messaging.Json(&req))
	if err != nil {
		t.Fatal(err)
	}

	// CREATE - with-readonly-space

	req = shares.ShareCrudRequest{
		Operation: "CREATE",
		Share:     entities.MakePrototype(&shares.SharePrototype{}),
	}
	req.Share.ShareId.Set("test-space-read-only")
	req.Share.Owner.Set("user")
	req.Share.ProviderId.Set("foo-read-only")
	req.Share.Path.Set("/bar/baz")
	req.Share.Recursive.Set(true)
	req.Share.IsDir.Set(true)
	req.Share.ReadOnly.Set(false)

	err = messaging.RequestVoid(context.Background(), nc, shares.ShareCrudTopic, messaging.Json(&req))
	if err != nil {
		t.Fatal(err)
	}

	// CREATE - readonly-with-readonly-space

	req = shares.ShareCrudRequest{
		Operation: "CREATE",
		Share:     entities.MakePrototype(&shares.SharePrototype{}),
	}
	req.Share.ShareId.Set("test-readonly-space-readonly")
	req.Share.Owner.Set("user")
	req.Share.ProviderId.Set("foo-read-only")
	req.Share.Path.Set("/bar/baz")
	req.Share.Recursive.Set(true)
	req.Share.IsDir.Set(true)
	req.Share.ReadOnly.Set(true)

	err = messaging.RequestVoid(context.Background(), nc, shares.ShareCrudTopic, messaging.Json(&req))
	if err != nil {
		t.Fatal(err)
	}

	// resolve empty path

	resolveReq := shares.ShareResolveRequest{
		ShareId: "test",
	}

	res := shares.ShareResolveResponse{}
	err = messaging.Request(context.Background(), nc, shares.ShareResolveTopic, messaging.Json(&resolveReq), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.Equal(t, "foo-resolved", res.ProviderId)
	assert.Equal(t, "/bar/baz", res.Path)
	assert.False(t, res.ReadOnly)

	// resolve file

	resolveReq = shares.ShareResolveRequest{
		ShareId: "test",
		Path:    "file.txt",
	}

	err = messaging.Request(context.Background(), nc, shares.ShareResolveTopic, messaging.Json(&resolveReq), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.Equal(t, "foo-resolved", res.ProviderId)
	assert.Equal(t, "/bar/baz/file.txt", res.Path)
	assert.False(t, res.ReadOnly)

	// resolve subfolder -> share not recursive -> expect error

	resolveReq = shares.ShareResolveRequest{
		ShareId: "test",
		Path:    "sub/file.txt",
	}

	err = messaging.Request(context.Background(), nc, shares.ShareResolveTopic, messaging.Json(&resolveReq), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.Equal(t, "", res.ProviderId)
	assert.Equal(t, "", res.Path)

	// UPDATE make recursive

	req = shares.ShareCrudRequest{
		Operation: "UPDATE",
		Share:     entities.MakePrototype(&shares.SharePrototype{}),
	}

	req.Share.ShareId.Set("test")
	req.Share.Recursive.Set(true)

	err = messaging.RequestVoid(context.Background(), nc, shares.ShareCrudTopic, messaging.Json(&req))
	if err != nil {
		t.Fatal(err)
	}

	// resolve subfolder

	resolveReq = shares.ShareResolveRequest{
		ShareId: "test",
		Path:    "sub/file.txt",
	}

	err = messaging.Request(context.Background(), nc, shares.ShareResolveTopic, messaging.Json(&resolveReq), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.Equal(t, "foo-resolved", res.ProviderId)
	assert.Equal(t, "/bar/baz/sub/file.txt", res.Path)
	assert.False(t, res.ReadOnly)

	// resolve subfolder in space subfolder

	resolveReq = shares.ShareResolveRequest{
		ShareId: "test-space-with-path",
		Path:    "sub/file.txt",
	}

	err = messaging.Request(context.Background(), nc, shares.ShareResolveTopic, messaging.Json(&resolveReq), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.Equal(t, "foo-resolved", res.ProviderId)
	assert.Equal(t, "/space/path/bar/baz/sub/file.txt", res.Path)
	assert.False(t, res.ReadOnly)

	// resolve read-only share

	resolveReq = shares.ShareResolveRequest{
		ShareId: "test-read-only",
		Path:    "sub/file.txt",
	}

	err = messaging.Request(context.Background(), nc, shares.ShareResolveTopic, messaging.Json(&resolveReq), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.Equal(t, "foo-resolved", res.ProviderId)
	assert.Equal(t, "/bar/baz/sub/file.txt", res.Path)
	assert.True(t, res.ReadOnly)

	// resolve read-only space

	resolveReq = shares.ShareResolveRequest{
		ShareId: "test-space-read-only",
		Path:    "sub/file.txt",
	}

	err = messaging.Request(context.Background(), nc, shares.ShareResolveTopic, messaging.Json(&resolveReq), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.Equal(t, "foo-resolved", res.ProviderId)
	assert.Equal(t, "/bar/baz/sub/file.txt", res.Path)
	assert.True(t, res.ReadOnly)

	// resolve read-only share and read-only space

	resolveReq = shares.ShareResolveRequest{
		ShareId: "test-readonly-space-readonly",
		Path:    "sub/file.txt",
	}

	err = messaging.Request(context.Background(), nc, shares.ShareResolveTopic, messaging.Json(&resolveReq), messaging.Json(&res))
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.Equal(t, "foo-resolved", res.ProviderId)
	assert.Equal(t, "/bar/baz/sub/file.txt", res.Path)
	assert.True(t, res.ReadOnly)
}
