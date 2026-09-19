// Copyright © 2026 Benjamin Schmitz

// This file is part of Seraph <https://github.com/Vortex375/seraph>.

// Seraph is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License
// as published by the Free Software Foundation,
// either version 3 of the License, or (at your option) any later version.

// Seraph is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.

// You should have received a copy of the GNU Affero General Public License
// along with Seraph.  If not, see <http://www.gnu.org/licenses/>.

// Package e2e runs the api-gateway's WebDAV endpoint end-to-end against the
// real stack it serves in production: a NATS-connected file-provider-dir
// backed by a TEMPORARY on-disk directory, the spaces service resolving a
// seeded space onto that provider, and the api-gateway's own gin engine
// fronting the golang.org/x/net/webdav.Handler with the atomic-PUT decorator
// - exactly the path a background backup PUT takes on a real device.
//
// Auth is disabled (auth.enabled=false) so no OIDC issuer is needed; the
// noAuth identity ("anonymous") is made a space admin, so the seeded space is
// visible to it. The file-provider's backing directory is a fresh temp dir
// under os.TempDir, so nothing the test writes touches the host's real
// files.
//
// The point of this test is the WebDAV write path the backup uses. Every
// verb the gallery upload path and the file browser exercise is driven
// against the live HTTP listener, so a regression at any layer - the gin
// route registration, the delegating space resolution, the atomic-PUT
// staging file, the fileprovider NATS client/server, or the on-disk
// webdav.Dir - shows up as a concrete status code here rather than only
// surfacing on a phone.
package e2e

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/spf13/viper"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"go.uber.org/fx/fxtest"
	xwebdav "golang.org/x/net/webdav"
	"go.mongodb.org/mongo-driver/mongo"
	"umbasa.net/seraph/api-gateway/auth"
	gwhandler "umbasa.net/seraph/api-gateway/gateway-handler"
	"umbasa.net/seraph/api-gateway/gateway"
	apidav "umbasa.net/seraph/api-gateway/spaces"
	"umbasa.net/seraph/api-gateway/webdav"
	apigallery "umbasa.net/seraph/api-gateway/gallery"
	"umbasa.net/seraph/file-indexer/fileindexer"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/gallery/gallery"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/mongodb"
	"umbasa.net/seraph/spaces/spaces"
	"umbasa.net/seraph/tracing"

	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"
)

// Constants for the seeded space + provider. The spaceProviderId ("storage")
// matches the one the backup sync pair on the phone uses, so a passing test
// here means the same path shape works against a freshly started stack; a
// failing one localises the regression to the gateway/provider layer rather
// than the client.
const (
	spaceProviderId = "storage"
	providerId      = "dir-test-provider"
)

var (
	natsServer  *server.Server
	mongoC      testcontainers.Container
	mongoUrl    string
	mongoDbName = "seraph_e2e"
	// Separate Mongo databases for the file-indexer and gallery services, matching
	// the per-service defaults in their main.go (seraph-files / seraph-gallery).
	// Distinct from mongoDbName (auth/spaces) so a test run never leaves gallery
	// state behind that a later run's auth/spaces teardown would not clean.
	fileIndexDbName  = "seraph_files_e2e"
	galleryDbName    = "seraph_gallery_e2e"
	mongoClient      *mongo.Client
	providerDir string
	fpServer    *fileprovider.FileProviderServer
	fpConn      *nats.Conn
	gatewayAddr string
	gatewayBase string
	// galleryProvider / fiConsumer are started in setup() so the gallery-pipeline
	// E2E test can exercise the full upload → file-indexer → gallery → delta path
	// against the same live stack the WebDAV verb suite uses.
	galleryProvider *gallery.GalleryProvider
	fiConsumer      fileindexer.Consumer
)

func TestMain(m *testing.M) {
	code := setup()
	if code != 0 {
		teardown()
		os.Exit(code)
	}
	code = m.Run()
	teardown()
	os.Exit(code)
}

// setup starts the shared infrastructure (embedded NATS with JetStream, a
// mongo testcontainer, an in-process file-provider-dir over NATS backed by
// a temp dir) and the api-gateway itself, then seeds a space pointing at
// the provider via the gateway's own /api/spaces endpoint. Returns a
// non-zero code only on a setup failure, so a misconfigured environment
// fails the suite loudly rather than as flaky individual tests.
func setup() int {
	ctx := context.Background()

	// --- embedded NATS with JetStream (spaces service requires a stream) ---
	natsStore, err := os.MkdirTemp("", "seraph-e2e-nats-*")
	if err != nil {
		fmt.Printf("e2e: nats store dir: %v\n", err)
		return 1
	}
	opts := &server.Options{
		Port:      server.RANDOM_PORT,
		JetStream: true,
		StoreDir:  natsStore,
	}
	natsServer, err = server.NewServer(opts)
	if err != nil {
		fmt.Printf("e2e: nats server: %v\n", err)
		return 1
	}
	natsServer.Start()
	if !natsServer.ReadyForConnections(10 * time.Second) {
		fmt.Println("e2e: embedded NATS server did not become ready")
		return 1
	}

	// --- mongo testcontainer ---
	mongoC, err = testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: testcontainers.ContainerRequest{
			Image:        "mongo:8",
			ExposedPorts: []string{"27017/tcp"},
			WaitingFor:   wait.ForLog("Waiting for connections").WithStartupTimeout(60 * time.Second),
		},
		Started: true,
	})
	if err != nil {
		fmt.Printf("e2e: mongo container: %v\n", err)
		return 1
	}
	endpoint, err := mongoC.Endpoint(ctx, "")
	if err != nil {
		fmt.Printf("e2e: mongo endpoint: %v\n", err)
		return 1
	}
	mongoUrl = fmt.Sprintf("mongodb://%s/", endpoint)

	// --- file-provider-dir over the shared NATS, backed by a temp dir ---
	providerDir, err = os.MkdirTemp("", "seraph-e2e-provider-*")
	if err != nil {
		fmt.Printf("e2e: provider dir: %v\n", err)
		return 1
	}
	fpConn, err = nats.Connect(natsServer.ClientURL())
	if err != nil {
		fmt.Printf("e2e: provider nats connect: %v\n", err)
		return 1
	}
	logger := logging.New(logging.Params{})
	logger.SetLevel(slog.LevelDebug)
	fpServer, err = fileprovider.NewFileProviderServer(fileprovider.ServerParams{
		Logger:  logger,
		Tracing: tracing.NewNoopTracing(),
		Nc:      fpConn,
		Js:      nil,
	}, providerId, xwebdav.Dir(providerDir), false)
	if err != nil {
		fmt.Printf("e2e: file provider server: %v\n", err)
		return 1
	}
	if err := fpServer.Start(); err != nil {
		fmt.Printf("e2e: file provider start: %v\n", err)
		return 1
	}

	// --- api-gateway: viper config + the webdav + gateway + auth modules.
	// Only the modules the WebDAV endpoint needs are wired; the gallery,
	// search, agents etc. handlers are omitted so their own service-discovery
	// subscribers do not need to be running. The webdav module's delegating fs
	// resolves /dav/p/storage/... by asking the spaces service, which is
	// started below over the same NATS conn, onto providerId, whose
	// fileprovider client the webdav module builds itself over that conn.
	gatewayAddr = freeAddr()
	gatewayBase = "http://" + gatewayAddr

	v := viper.New()
	v.Set("auth.enabled", false)
	v.Set("mongo.url", mongoUrl)
	v.Set("mongo.db", mongoDbName)
	v.Set("nats.url", natsServer.ClientURL())
	v.Set("gateway.address", gatewayAddr)
	v.Set("gateway.appLocation", providerDir)     // any existing dir; not exercised
	v.Set("gateway.webAppLocation", providerDir)  // any existing dir; not exercised
	v.Set("tracing.serviceName", "api-gateway-e2e")

	appConn, err := nats.Connect(natsServer.ClientURL())
	if err != nil {
		fmt.Printf("e2e: app nats connect: %v\n", err)
		return 1
	}
	appJs, err := jetstream.New(appConn)
	if err != nil {
		fmt.Printf("e2e: app jetstream: %v\n", err)
		return 1
	}

	// A single shared fx lifecycle drives the start/stop hooks of the mongo
	// client (stop = disconnect) and the gateway (start = listen). fxtest
	// gives us this without running a real fx app; calling Start triggers
	// every registered start hook in registration order.
	lc := fxtest.NewLifecycle(&testing.T{})

	// mongo client + db for auth (token store) + spaces. The lifecycle's
	// stop hook disconnects the client in teardown.
	mongoRes, err := mongodb.NewClient(mongodb.ClientParams{
		Viper:   v,
		Tracing: tracing.NewNoopTracing(),
		Lc:      lc,
	})
	if err != nil {
		fmt.Printf("e2e: mongo client: %v\n", err)
		return 1
	}
	mongoClient = mongoRes.Client
	db := mongoRes.Client.Database(mongoDbName)

	// spaces service: started directly (not via fx) so its NATS subscribers
	// for the resolve/crud topics are up before the gateway serves any
	// WebDAV request that needs them.
	spacesRes, err := spaces.New(spaces.Params{
		Nc:      appConn,
		Js:      appJs,
		Db:      db,
		Logger:  logger,
		Tracing: tracing.NewNoopTracing(),
		Mig:     spaces.Migrations{},
	})
	if err != nil {
		fmt.Printf("e2e: spaces.New: %v\n", err)
		return 1
	}
	if err := spacesRes.SpacesProvider.Start(); err != nil {
		fmt.Printf("e2e: spaces.Start: %v\n", err)
		return 1
	}
	// register spaces stop for teardown
	spacesStop := spacesRes.SpacesProvider.Stop

	// --- file-indexer: consumes FileInfoEvent (from the file-provider's
	// stat/readdir) and publishes FileChangedEvent (which the gallery
	// service consumes). Needs its own Mongo db and the shared NATS + Js.
	// Started directly (not via fx) like spaces so its streams/consumers are
	// up before the gallery service starts consuming FileChangedEvent.
	fiV := viper.New()
	fiV.Set("mongo.url", mongoUrl)
	fiV.Set("mongo.db", fileIndexDbName)
	fiV.Set("fileindexer.parallel", 2)
	fiRes, err := fileindexer.NewConsumer(fileindexer.ConsumerParams{
		Nc:      appConn,
		Js:      appJs,
		Db:      mongoClient.Database(fileIndexDbName),
		Logger:  logger,
		Viper:   fiV,
		Tracing: tracing.NewNoopTracing(),
		Mig:     fileindexer.Migrations{},
	})
	if err != nil {
		fmt.Printf("e2e: file-indexer consumer: %v\n", err)
		return 1
	}
	fiConsumer = fiRes
	// file-indexer list answers the FileIndexListRequest gallery backfill sends
	// (see backfill.go's requestFileIndexPage); register its start/stop on the
	// shared lifecycle so lc.Start()/lc.Stop() drives it.
	_, err = fileindexer.NewList(fileindexer.ListParams{
		Nc:      appConn,
		Db:      mongoClient.Database(fileIndexDbName),
		Logger:  logger,
		Tracing: tracing.NewNoopTracing(),
		Mig:     fileindexer.Migrations{},
		Lc:      lc,
	})
	if err != nil {
		fmt.Printf("e2e: file-indexer list: %v\n", err)
		return 1
	}

	// --- gallery service: consumes FileChangedEvent, serves the gallery
	// delta/list/crud NATS topics. Started directly (not via fx) like spaces so
	// its NATS subscribers are up before the gateway serves any gallery request.
	// Needs spaces running (refreshPrefixCache at Start resolves every folder).
	galleryRes, err := gallery.New(gallery.Params{
		Nc:      appConn,
		Js:      appJs,
		Db:      mongoClient.Database(galleryDbName),
		Logger:  logger,
		Tracing: tracing.NewNoopTracing(),
		Mig:     gallery.Migrations{},
	})
	if err != nil {
		fmt.Printf("e2e: gallery.New: %v\n", err)
		return 1
	}
	galleryProvider = galleryRes.GalleryProvider

	// auth: noAuth because auth.enabled=false. Needs Js + Db + Mig.
	authRes, err := auth.New(auth.Params{
		Log:   logger,
		Viper: v,
		Js:    appJs,
		Db:    db,
		Mig:   auth.Migrations{},
	})
	if err != nil {
		fmt.Printf("e2e: auth.New: %v\n", err)
		return 1
	}

	// webdav module: builds the delegating fs + registers the
	// /dav/*path gin routes when Setup is called by the gateway.
	webdavRes := webdav.New(webdav.Params{
		Log:  logger,
		Nc:   appConn,
		Auth: authRes.Auth,
	})

	// spaces gateway handler: serves POST /api/spaces the test uses to seed
	// the space the WebDAV endpoint resolves. Without it, the POST 404s.
	spacesHandler := apidav.New(apidav.Params{
		Log:  logger,
		Nc:   appConn,
		Auth: authRes.Auth,
	})

	// gallery gateway handler: serves GET/POST /api/gallery/* the gallery-
	// pipeline E2E test uses (source-folders CRUD, delta feed). Without it,
	// those routes 404.
	galleryHandler := apigallery.New(apigallery.Params{
		Log:  logger,
		Nc:   appConn,
		Auth: authRes.Auth,
	})

	// gateway: registers start (listen) + stop hooks on the shared lifecycle;
	// lc.Start() below triggers the listen so the HTTP server is up before
	// any test runs. Only the webdav handler is passed, keeping the test
	// focused on the WebDAV endpoint.
	gatewayParams := gateway.Params{
		Log:     logger,
		Viper:   v,
		Auth:    authRes.Auth,
		Tracing: tracing.NewNoopTracing(),
		Handlers: []gwhandler.GatewayHandler{
			webdavRes.Handler,
			spacesHandler.Handler,
			galleryHandler.Handler,
		},
		Lc: lc,
	}
	gateway.New(gatewayParams)
	// run every registered start hook: gateway listens, mongo connects.
	lc.Start(context.Background())

	// wait for the http listener to actually accept connections, so the
	// first test does not race the server's goroutine.
	if !waitForListen(gatewayAddr, 5*time.Second) {
		fmt.Println("e2e: api-gateway did not start listening in time")
		return 1
	}

	// --- seed a space pointing at the in-process file provider, via the
	// gateway's own /api/spaces endpoint (noAuth makes "anonymous" a space
	// admin, so the POST is authorised). ---
	if err := seedSpaceViaHttp(); err != nil {
		fmt.Printf("e2e: seedSpace: %v\n", err)
		return 1
	}

	// --- start the file-indexer consumer and gallery provider now that the
	// gateway is listening, spaces is up (gallery resolves folders), and the
	// streams file-indexer/gallery create in their constructors exist. The
	// file-provider publishes FileInfoEvents via core NATS; JetStream captures
	// them into SERAPH_FILE_INFO (created by file-indexer.NewConsumer). ---
	if err := fiConsumer.Start(); err != nil {
		fmt.Printf("e2e: file-indexer consumer start: %v\n", err)
		return 1
	}
	if err := galleryProvider.Start(); err != nil {
		fmt.Printf("e2e: gallery provider start: %v\n", err)
		return 1
	}

	// register teardown for everything started here
	_teardownExtras = func() {
		_ = galleryProvider.Stop()
		fiConsumer.Stop()
		lc.Stop(context.Background()) // gateway stop + mongo disconnect
		spacesStop()
		appConn.Close()
	}
	return 0
}

var _teardownExtras func()

func teardown() {
	if _teardownExtras != nil {
		_teardownExtras()
	}
	if fpServer != nil {
		fpServer.Stop(true)
	}
	if fpConn != nil {
		fpConn.Close()
	}
	if natsServer != nil {
		natsServer.Shutdown()
	}
	if mongoC != nil {
		_ = testcontainers.TerminateContainer(mongoC)
	}
}

// seedSpaceViaHttp creates a space with one file provider whose providerId
// matches the in-process file-provider-dir and whose path is the provider
// root, so WebDAV paths like /dav/p/storage/<anything> resolve to
// <providerDir>/<anything>. Uses the gateway's own /api/spaces POST so the
// request traverses the same auth + spaces-CRUD path a real client would.
func seedSpaceViaHttp() error {
	body := map[string]any{
		"title": "e2e space",
		"users": []string{"anonymous"},
		"fileProviders": []map[string]any{{
			"spaceProviderId": spaceProviderId,
			"providerId":      providerId,
			"path":            "/",
			"readOnly":        false,
		}},
	}
	b, _ := json.Marshal(body)
	resp, err := http.Post(gatewayBase+"/api/spaces", "application/json", bytes.NewReader(b))
	if err != nil {
		return fmt.Errorf("spaces POST: %w", err)
	}
	defer resp.Body.Close()
	rb, _ := io.ReadAll(resp.Body)
	if resp.StatusCode >= 400 {
		return fmt.Errorf("spaces POST status %d: %s", resp.StatusCode, rb)
	}
	return nil
}

func freeAddr() string {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	addr := l.Addr().String()
	l.Close()
	return addr
}

func waitForListen(addr string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		c, err := net.DialTimeout("tcp", addr, 200*time.Millisecond)
		if err == nil {
			c.Close()
			return true
		}
	}
	return false
}

// --- HTTP/WebDAV client helpers ---

func do(t *testing.T, method, path string, body io.Reader, headers ...string) *http.Response {
	t.Helper()
	req, err := http.NewRequest(method, gatewayBase+path, body)
	require.NoError(t, err)
	for i := 0; i+1 < len(headers); i += 2 {
		req.Header.Set(headers[i], headers[i+1])
	}
	resp, err := http.DefaultClient.Do(req)
	require.NoError(t, err)
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func putFile(t *testing.T, path string, content []byte) *http.Response {
	t.Helper()
	return do(t, http.MethodPut, path, bytes.NewReader(content))
}

func getBody(t *testing.T, resp *http.Response) []byte {
	t.Helper()
	b, err := io.ReadAll(resp.Body)
	require.NoError(t, err)
	return b
}

// --- WebDAV verb suite ---
//
// runWebDavVerbSuite drives every WebDAV verb the gallery upload path and the
// file browser use against the live api-gateway, asserting both the HTTP
// status and (where applicable) the on-disk result in [diskRoot]. [davPrefix]
// is the WebDAV path prefix that resolves onto the provider under test - e.g.
// "/dav/p/storage" for the dir provider and "/dav/p/smbstorage" for the SMB
// provider - so the same suite runs unchanged against either backing store.
//
// Subtests are nested under the caller's name, so `go test -v` reports
// TestE2EDirProvider/PUT_file and TestE2ESmbProvider/PUT_file side by side,
// making a provider-specific regression immediately visible.
func runWebDavVerbSuite(t *testing.T, diskRoot, davPrefix string) {
	t.Helper()

	p := func(rel string) string { return davPrefix + rel }

	t.Run("PUT_file", func(t *testing.T) {
		resp := putFile(t, p("/e2e-put.txt"), []byte("hello e2e"))
		if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusNoContent {
			t.Fatalf("PUT new file: want 201/204, got %d (body=%s)", resp.StatusCode, getBody(t, resp))
		}
		disk, err := os.ReadFile(filepath.Join(diskRoot, "e2e-put.txt"))
		require.NoError(t, err)
		assert.Equal(t, "hello e2e", string(disk))
	})

	t.Run("PUT_overwrite", func(t *testing.T) {
		putFile(t, p("/e2e-ow.txt"), []byte("first"))
		resp := putFile(t, p("/e2e-ow.txt"), []byte("second"))
		if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusNoContent {
			t.Fatalf("PUT overwrite: want 201/204, got %d (body=%s)", resp.StatusCode, getBody(t, resp))
		}
		disk, err := os.ReadFile(filepath.Join(diskRoot, "e2e-ow.txt"))
		require.NoError(t, err)
		assert.Equal(t, "second", string(disk))
	})

	t.Run("PUT_large", func(t *testing.T) {
		// Larger than the fileprovider single-NATS-message cap (768KB) so the
		// buffered multi-chunk write path is exercised - the path the phone's
		// 3.5MB upload takes.
		big := bytes.Repeat([]byte("Z"), 3*1024*1024) // 3 MiB
		resp := putFile(t, p("/e2e-large.bin"), big)
		if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusNoContent {
			t.Fatalf("PUT large: want 201/204, got %d (body=%s)", resp.StatusCode, getBody(t, resp))
		}
		disk, err := os.ReadFile(filepath.Join(diskRoot, "e2e-large.bin"))
		require.NoError(t, err)
		assert.Equal(t, len(big), len(disk))
		assert.True(t, bytes.Equal(big, disk))
	})

	t.Run("GET_file", func(t *testing.T) {
		putFile(t, p("/e2e-get.txt"), []byte("get me"))
		resp := do(t, http.MethodGet, p("/e2e-get.txt"), nil)
		body := getBody(t, resp)
		require.Equal(t, http.StatusOK, resp.StatusCode, "GET file: %s", body)
		assert.Equal(t, "get me", string(body))
	})

	t.Run("HEAD_file", func(t *testing.T) {
		putFile(t, p("/e2e-head.txt"), []byte("head me"))
		resp := do(t, http.MethodHead, p("/e2e-head.txt"), nil)
		require.Equal(t, http.StatusOK, resp.StatusCode, "HEAD file: %s", getBody(t, resp))
		assert.Empty(t, getBody(t, resp), "HEAD must not return a body")
	})

	t.Run("OPTIONS_file", func(t *testing.T) {
		putFile(t, p("/e2e-opt.txt"), []byte("x"))
		resp := do(t, http.MethodOptions, p("/e2e-opt.txt"), nil)
		require.Equal(t, http.StatusOK, resp.StatusCode, "OPTIONS file: %s", getBody(t, resp))
		allow := resp.Header.Get("Allow")
		assert.NotEmpty(t, allow, "OPTIONS must return an Allow header")
		t.Logf("OPTIONS Allow: %s", allow)
	})

	t.Run("OPTIONS_nonexistent", func(t *testing.T) {
		// The webdav_client library sends an OPTIONS before every PUT/GET; a 405
		// here would propagate to the client as the request error the phone saw.
		resp := do(t, http.MethodOptions, p("/never-existed.txt"), nil)
		assert.True(t, resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusNotFound,
			"OPTIONS on a nonexistent file should be 200 or 404, got %d (body=%s)", resp.StatusCode, getBody(t, resp))
	})

	t.Run("MKCOL_dir", func(t *testing.T) {
		resp := do(t, "MKCOL", p("/e2e-dir"), nil)
		require.Equal(t, http.StatusCreated, resp.StatusCode, "MKCOL new dir: %s", getBody(t, resp))
		st, err := os.Stat(filepath.Join(diskRoot, "e2e-dir"))
		require.NoError(t, err)
		assert.True(t, st.IsDir())
	})

	t.Run("MKCOL_existing_dir", func(t *testing.T) {
		do(t, "MKCOL", p("/e2e-dir2"), nil)
		resp := do(t, "MKCOL", p("/e2e-dir2"), nil)
		// 405 Method Not Allowed is the WebDAV convention for "collection already
		// exists" - webdav_client relies on this to treat MKCOL as mkdirAll.
		assert.Equal(t, http.StatusMethodNotAllowed, resp.StatusCode,
			"MKCOL existing dir should be 405, got %d (body=%s)", resp.StatusCode, getBody(t, resp))
	})

	t.Run("MKCOL_nested", func(t *testing.T) {
		// webdav_client's mkdirAll does a top-level MKCOL, falls back to a
		// 409 -> per-segment walk. A nested path whose parents do not exist
		// exercises both.
		resp := do(t, "MKCOL", p("/e2e-nest/a/b/c"), nil)
		if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusConflict {
			t.Fatalf("MKCOL nested (no parent): want 201/409, got %d (body=%s)", resp.StatusCode, getBody(t, resp))
		}
	})

	t.Run("PUT_into_missing_dir", func(t *testing.T) {
		// The phone's upload path: PUT straight to /storage/Benni/Photos/Pixel 10/file
		// where the intermediate dirs do not exist yet. The atomic-PUT decorator
		// now creates the parent dir server-side, so this succeeds regardless of
		// whether the client ran mkdirAll first.
		resp := putFile(t, p("/Benni/Photos/Pixel 10/PXL_e2e.jpg"), []byte("pixel"))
		if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusNoContent {
			t.Fatalf("PUT into missing dir: want 201/204, got %d (body=%s)", resp.StatusCode, getBody(t, resp))
		}
		disk, err := os.ReadFile(filepath.Join(diskRoot, "Benni/Photos/Pixel 10/PXL_e2e.jpg"))
		require.NoError(t, err)
		assert.Equal(t, "pixel", string(disk))
	})

	t.Run("PUT_phone_upload_sequence", func(t *testing.T) {
		// Mirrors the EXACT sequence the seraph_app's HeadlessWebDavBackend +
		// webdav_client wdWriteWithBytes drive for a gallery upload: an OPTIONS
		// preflight on the file, then mkdirAll on the parent collection, then the
		// PUT. This is what the phone's background backup does.
		const fname = "/IMG_e2e.jpg"
		file := p("/Phone/Photos/Pixel 10" + fname)

		// 1. OPTIONS preflight (webdav_client.wdOptions before every read/write).
		optResp := do(t, http.MethodOptions, file, nil)
		if optResp.StatusCode != http.StatusOK {
			t.Fatalf("OPTIONS preflight: want 200, got %d (body=%s)", optResp.StatusCode, getBody(t, optResp))
		}

		// 2. mkdirAll on the parent collection - the path webdav_client computes
		// from the file path (everything up to and including the last '/'). The
		// client walks segments RELATIVE to its base (/dav/p), so the walk here
		// does too: split the part after /dav/p.
		const davBase = "/dav/p"
		parent := strings.TrimSuffix(strings.TrimSuffix(file, "/"), fname) + "/"
		parentRel := strings.TrimPrefix(parent, davBase)
		mkResp := do(t, "MKCOL", parent, nil)
		if mkResp.StatusCode != http.StatusCreated && mkResp.StatusCode != http.StatusMethodNotAllowed {
			if mkResp.StatusCode == http.StatusConflict {
				segments := strings.Split(strings.Trim(parentRel, "/"), "/")
				sub := davBase + "/"
				for _, seg := range segments {
					sub += seg + "/"
					sr := do(t, "MKCOL", sub, nil)
					if sr.StatusCode != http.StatusCreated && sr.StatusCode != http.StatusMethodNotAllowed {
						t.Fatalf("mkdirAll walk MKCOL %s: want 201/405, got %d (body=%s)", sub, sr.StatusCode, getBody(t, sr))
					}
				}
			} else {
				t.Fatalf("mkdirAll parent MKCOL %s: want 201/405/409, got %d (body=%s)", parent, mkResp.StatusCode, getBody(t, mkResp))
			}
		}

		// 3. PUT the file - the staging openFile must succeed now that the parent
		// collection exists.
		resp := putFile(t, file, []byte("pixel"))
		if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusNoContent {
			t.Fatalf("PUT after mkdirAll: want 201/204, got %d (body=%s)", resp.StatusCode, getBody(t, resp))
		}
		disk, err := os.ReadFile(filepath.Join(diskRoot, "Phone/Photos/Pixel 10/IMG_e2e.jpg"))
		require.NoError(t, err)
		assert.Equal(t, "pixel", string(disk))
	})

	t.Run("PROPFIND_file", func(t *testing.T) {
		putFile(t, p("/e2e-propfind.txt"), []byte("prop me"))
		resp := do(t, "PROPFIND", p("/e2e-propfind.txt"), strings.NewReader(propfindBody), "Depth", "0", "Content-Type", "application/xml")
		require.Equal(t, http.StatusMultiStatus, resp.StatusCode, "PROPFIND file: %s", getBody(t, resp))
	})

	t.Run("PROPFIND_dir", func(t *testing.T) {
		do(t, "MKCOL", p("/e2e-pfdir"), nil)
		putFile(t, p("/e2e-pfdir/inner.txt"), []byte("inner"))
		resp := do(t, "PROPFIND", p("/e2e-pfdir"), strings.NewReader(propfindBody), "Depth", "1", "Content-Type", "application/xml")
		require.Equal(t, http.StatusMultiStatus, resp.StatusCode, "PROPFIND dir: %s", getBody(t, resp))
	})

	t.Run("PROPFIND_nonexistent", func(t *testing.T) {
		resp := do(t, "PROPFIND", p("/no-such-file.txt"), strings.NewReader(propfindBody), "Depth", "0", "Content-Type", "application/xml")
		assert.Equal(t, http.StatusNotFound, resp.StatusCode,
			"PROPFIND nonexistent: want 404, got %d (body=%s)", resp.StatusCode, getBody(t, resp))
	})

	t.Run("DELETE_file", func(t *testing.T) {
		putFile(t, p("/e2e-del.txt"), []byte("delete me"))
		resp := do(t, http.MethodDelete, p("/e2e-del.txt"), nil)
		require.Equal(t, http.StatusNoContent, resp.StatusCode, "DELETE file: %s", getBody(t, resp))
		_, err := os.Stat(filepath.Join(diskRoot, "e2e-del.txt"))
		assert.True(t, os.IsNotExist(err), "file should be gone on disk")
	})

	t.Run("DELETE_empty_dir", func(t *testing.T) {
		do(t, "MKCOL", p("/e2e-emptydir"), nil)
		resp := do(t, http.MethodDelete, p("/e2e-emptydir"), nil)
		require.Equal(t, http.StatusNoContent, resp.StatusCode, "DELETE empty dir: %s", getBody(t, resp))
		_, err := os.Stat(filepath.Join(diskRoot, "e2e-emptydir"))
		assert.True(t, os.IsNotExist(err), "empty dir should be gone on disk")
	})

	t.Run("DELETE_nonempty_dir_recursive", func(t *testing.T) {
		do(t, "MKCOL", p("/e2e-recdir"), nil)
		putFile(t, p("/e2e-recdir/a.txt"), []byte("a"))
		do(t, "MKCOL", p("/e2e-recdir/sub"), nil)
		putFile(t, p("/e2e-recdir/sub/b.txt"), []byte("b"))
		resp := do(t, http.MethodDelete, p("/e2e-recdir"), nil)
		require.Equal(t, http.StatusNoContent, resp.StatusCode, "DELETE non-empty dir: %s", getBody(t, resp))
		_, err := os.Stat(filepath.Join(diskRoot, "e2e-recdir"))
		assert.True(t, os.IsNotExist(err), "non-empty dir should be gone recursively")
	})

	t.Run("MOVE_rename_file", func(t *testing.T) {
		putFile(t, p("/e2e-mov-src.txt"), []byte("move me"))
		resp := do(t, "MOVE", p("/e2e-mov-src.txt"), nil, "Destination", gatewayBase+p("/e2e-mov-dst.txt"))
		require.Equal(t, http.StatusCreated, resp.StatusCode, "MOVE rename file: %s", getBody(t, resp))
		disk, err := os.ReadFile(filepath.Join(diskRoot, "e2e-mov-dst.txt"))
		require.NoError(t, err)
		assert.Equal(t, "move me", string(disk))
		_, err = os.Stat(filepath.Join(diskRoot, "e2e-mov-src.txt"))
		assert.True(t, os.IsNotExist(err), "source should be gone after MOVE")
	})

	t.Run("COPY_file", func(t *testing.T) {
		putFile(t, p("/e2e-cpy-src.txt"), []byte("copy me"))
		resp := do(t, "COPY", p("/e2e-cpy-src.txt"), nil, "Destination", gatewayBase+p("/e2e-cpy-dst.txt"))
		require.Equal(t, http.StatusCreated, resp.StatusCode, "COPY file: %s", getBody(t, resp))
		disk, err := os.ReadFile(filepath.Join(diskRoot, "e2e-cpy-dst.txt"))
		require.NoError(t, err)
		assert.Equal(t, "copy me", string(disk))
		_, err = os.Stat(filepath.Join(diskRoot, "e2e-cpy-src.txt"))
		assert.NoError(t, err, "source should still exist after COPY")
	})

	t.Run("PUT_atomic_no_partial_on_abort", func(t *testing.T) {
		// The atomic-PUT decorator must leave NOTHING at the destination if the
		// upload body is truncated. Simulate a dropped upload by opening a raw
		// TCP connection, sending a PUT with a Content-Length that overstates the
		// body, then closing the connection mid-stream.
		conn, err := net.Dial("tcp", gatewayAddr)
		require.NoError(t, err)
		t.Cleanup(func() { conn.Close() })
		file := p("/e2e-abort.bin")
		const claimedLen = 1024 * 1024
		reqStr := "PUT " + file + " HTTP/1.1\r\n" +
			"Host: " + gatewayAddr + "\r\n" +
			"Content-Length: " + fmt.Sprintf("%d", claimedLen) + "\r\n" +
			"Connection: close\r\n\r\n" +
			"only-a-few-bytes"
		_, err = conn.Write([]byte(reqStr))
		require.NoError(t, err)
		conn.Close()
		time.Sleep(200 * time.Millisecond)
		_, err = os.Stat(filepath.Join(diskRoot, "e2e-abort.bin"))
		assert.True(t, os.IsNotExist(err), "destination must not exist after an aborted PUT, got err=%v", err)
		files, err := os.ReadDir(diskRoot)
		require.NoError(t, err)
		for _, f := range files {
			name := f.Name()
			if strings.HasPrefix(name, ".seraph-upload-") && strings.HasSuffix(name, ".part") {
				t.Errorf("leftover staging file after abort: %s", name)
			}
		}
	})
}

// TestE2EDirProvider runs the full WebDAV verb suite against the file-provider-dir
// backing the "storage" space seeded in TestMain. This is the suite that
// caught the missing-parent-dir 405; it stays green as the regression guard
// for the local-dir provider.
func TestE2EDirProvider(t *testing.T) {
	runWebDavVerbSuite(t, providerDir, "/dav/p/storage")
}

// propfindBody is a minimal PROPFIND request body asking for the basic
// properties; golang.org/x/net/webdav accepts an empty body too, but sending
// this matches what real clients (webdav_client.readProps) send.
const propfindBody = `<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:allprop/>
</D:propfind>`
