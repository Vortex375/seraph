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
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/mongodb"
	"umbasa.net/seraph/shares/shares"
)

var natsServer *server.Server
var mongoContainer testcontainers.Container
var mongoUrl string
var migrations shares.Migrations
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
	v.Set("mongo.db", "shares_test")

	migrations, err = shares.NewMigrations(v)
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

	res, err := mongodb.NewClient(mongodb.ClientParams{
		Viper: v,
		Lc:    fxtest.NewLifecycle(t),
	})
	if err != nil {
		t.Fatal(err)
	}
	mongoClient := res.Client

	logger := logging.New(logging.Params{})
	logger.SetLevel(slog.LevelDebug)
	db := mongoClient.Database("shares_test")

	res2, _ := shares.New(shares.Params{
		Nc:     nc,
		Logger: logger,
		Db:     db,
	})

	return res2.SharesProvider, nc, db
}

func TestShareCrud(t *testing.T) {
	sharesProvider, nc, _ := getSharesProvider(t)

	sharesProvider.Start()
	defer sharesProvider.Stop()

	// CREATE

	req := shares.ShareCrudRequest{
		Operation: "CREATE",
		Share: &shares.Share{
			ShareID:     "test",
			Owner:       "user",
			Title:       "some title",
			Description: "some description",
			ProviderID:  "foo",
			Path:        "/bar/baz",
			Recursive:   true,
			IsDir:       true,
		},
	}

	res := shares.ShareCrudResponse{}
	err := messaging.Request(nc, shares.ShareCrudTopic, &req, &res)
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.NotNil(t, res.Share)
	assert.Equal(t, "test", res.Share.ShareID)
	assert.Equal(t, "user", res.Share.Owner)
	assert.Equal(t, "some title", res.Share.Title)
	assert.Equal(t, "some description", res.Share.Description)
	assert.Equal(t, "foo", res.Share.ProviderID)
	assert.Equal(t, "/bar/baz", res.Share.Path)
	assert.Equal(t, true, res.Share.Recursive)
	assert.Equal(t, true, res.Share.IsDir)

	// CREATE duplicate -> expect error

	req = shares.ShareCrudRequest{
		Operation: "CREATE",
		Share: &shares.Share{
			ShareID:     "test",
			Owner:       "user",
			Title:       "some title",
			Description: "some description",
			ProviderID:  "foo",
			Path:        "/bar/baz",
			Recursive:   true,
			IsDir:       true,
		},
	}

	err = messaging.Request(nc, shares.ShareCrudTopic, &req, &res)
	if err != nil {
		t.Fatal(err)
	}

	assert.NotEqual(t, "", res.Error)

	// UPDATE

	req = shares.ShareCrudRequest{
		Operation: "UPDATE",
		Share: &shares.Share{
			ShareID:     "test",
			Owner:       "user",
			Title:       "some other title",
			Description: "some other description",
			ProviderID:  "foo",
			Path:        "/bar/baz",
			Recursive:   true,
			IsDir:       true,
		},
	}

	err = messaging.Request(nc, shares.ShareCrudTopic, &req, &res)
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.Equal(t, "some other title", res.Share.Title)
	assert.Equal(t, "some other description", res.Share.Description)

	// READ

	req = shares.ShareCrudRequest{
		Operation: "READ",
		Share: &shares.Share{
			ShareID: "test",
		},
	}

	err = messaging.Request(nc, shares.ShareCrudTopic, &req, &res)
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.NotNil(t, res.Share)
	assert.Equal(t, "test", res.Share.ShareID)
	assert.Equal(t, "user", res.Share.Owner)
	assert.Equal(t, "some other title", res.Share.Title)
	assert.Equal(t, "some other description", res.Share.Description)
	assert.Equal(t, "foo", res.Share.ProviderID)
	assert.Equal(t, "/bar/baz", res.Share.Path)
	assert.Equal(t, true, res.Share.Recursive)
	assert.Equal(t, true, res.Share.IsDir)

	// DELETE

	req = shares.ShareCrudRequest{
		Operation: "DELETE",
		Share: &shares.Share{
			ShareID: "test",
		},
	}

	err = messaging.Request(nc, shares.ShareCrudTopic, &req, &res)
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)

	// READ again -> expect error
	req = shares.ShareCrudRequest{
		Operation: "READ",
		Share: &shares.Share{
			ShareID: "test",
		},
	}

	err = messaging.Request(nc, shares.ShareCrudTopic, &req, &res)

	assert.NotEqual(t, "", res.Error)
}

func TestShareResolve(t *testing.T) {
	sharesProvider, nc, _ := getSharesProvider(t)

	sharesProvider.Start()
	defer sharesProvider.Stop()

	// CREATE

	req := shares.ShareCrudRequest{
		Operation: "CREATE",
		Share: &shares.Share{
			ShareID:    "test",
			Owner:      "user",
			ProviderID: "foo",
			Path:       "/bar/baz",
			Recursive:  false,
			IsDir:      true,
		},
	}

	err := messaging.RequestVoid(nc, shares.ShareCrudTopic, &req)
	if err != nil {
		t.Fatal(err)
	}

	// resolve empty path

	resolveReq := shares.ShareResolveRequest{
		ShareID: "test",
	}

	res := shares.ShareResolveResponse{}
	err = messaging.Request(nc, shares.ShareResolveTopic, &resolveReq, &res)
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.Equal(t, "foo", res.ProviderID)
	assert.Equal(t, "/bar/baz", res.Path)

	// resolve file

	resolveReq = shares.ShareResolveRequest{
		ShareID: "test",
		Path:    "file.txt",
	}

	err = messaging.Request(nc, shares.ShareResolveTopic, &resolveReq, &res)
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.Equal(t, "foo", res.ProviderID)
	assert.Equal(t, "/bar/baz/file.txt", res.Path)

	// resolve subfolder -> share not recursive -> expect error

	resolveReq = shares.ShareResolveRequest{
		ShareID: "test",
		Path:    "sub/file.txt",
	}

	err = messaging.Request(nc, shares.ShareResolveTopic, &resolveReq, &res)
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.Equal(t, "", res.ProviderID)
	assert.Equal(t, "", res.Path)

	// UPDATE make recursive

	req = shares.ShareCrudRequest{
		Operation: "UPDATE",
		Share: &shares.Share{
			ShareID:    "test",
			Owner:      "user",
			ProviderID: "foo",
			Path:       "/bar/baz",
			Recursive:  true,
			IsDir:      true,
		},
	}

	err = messaging.RequestVoid(nc, shares.ShareCrudTopic, &req)
	if err != nil {
		t.Fatal(err)
	}

	// resolve subfolder

	resolveReq = shares.ShareResolveRequest{
		ShareID: "test",
		Path:    "sub/file.txt",
	}

	err = messaging.Request(nc, shares.ShareResolveTopic, &resolveReq, &res)
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, "", res.Error)
	assert.Equal(t, "foo", res.ProviderID)
	assert.Equal(t, "/bar/baz/sub/file.txt", res.Path)
}
