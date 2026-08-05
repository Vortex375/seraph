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
	"umbasa.net/seraph/api-gateway/auth"
	gwhandler "umbasa.net/seraph/api-gateway/gateway-handler"
	"umbasa.net/seraph/api-gateway/gateway"
	apidav "umbasa.net/seraph/api-gateway/spaces"
	"umbasa.net/seraph/api-gateway/webdav"
	"umbasa.net/seraph/file-provider/fileprovider"
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
	providerDir string
	fpServer    *fileprovider.FileProviderServer
	fpConn      *nats.Conn
	gatewayAddr string
	gatewayBase string
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

	// register teardown for everything started here
	_teardownExtras = func() {
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

// --- WebDAV verb tests ---

func TestE2E_PUT_file(t *testing.T) {
	resp := putFile(t, "/dav/p/storage/e2e-put.txt", []byte("hello e2e"))
	// 201 created or 204 no content (overwrite); both are success.
	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusNoContent {
		t.Fatalf("PUT new file: want 201/204, got %d (body=%s)", resp.StatusCode, getBody(t, resp))
	}
	disk, err := os.ReadFile(filepath.Join(providerDir, "e2e-put.txt"))
	require.NoError(t, err)
	assert.Equal(t, "hello e2e", string(disk))
}

func TestE2E_PUT_overwrite(t *testing.T) {
	putFile(t, "/dav/p/storage/e2e-ow.txt", []byte("first"))
	resp := putFile(t, "/dav/p/storage/e2e-ow.txt", []byte("second"))
	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusNoContent {
		t.Fatalf("PUT overwrite: want 201/204, got %d (body=%s)", resp.StatusCode, getBody(t, resp))
	}
	disk, err := os.ReadFile(filepath.Join(providerDir, "e2e-ow.txt"))
	require.NoError(t, err)
	assert.Equal(t, "second", string(disk))
}

func TestE2E_PUT_large(t *testing.T) {
	// Larger than the fileprovider single-NATS-message cap (768KB) so the
	// buffered multi-chunk write path is exercised - the path the phone's
	// 3.5MB upload takes.
	big := bytes.Repeat([]byte("Z"), 3*1024*1024) // 3 MiB
	resp := putFile(t, "/dav/p/storage/e2e-large.bin", big)
	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusNoContent {
		t.Fatalf("PUT large: want 201/204, got %d (body=%s)", resp.StatusCode, getBody(t, resp))
	}
	disk, err := os.ReadFile(filepath.Join(providerDir, "e2e-large.bin"))
	require.NoError(t, err)
	assert.Equal(t, len(big), len(disk))
	assert.True(t, bytes.Equal(big, disk))
}

func TestE2E_GET_file(t *testing.T) {
	putFile(t, "/dav/p/storage/e2e-get.txt", []byte("get me"))
	resp := do(t, http.MethodGet, "/dav/p/storage/e2e-get.txt", nil)
	body := getBody(t, resp)
	require.Equal(t, http.StatusOK, resp.StatusCode, "GET file: %s", body)
	assert.Equal(t, "get me", string(body))
}

func TestE2E_HEAD_file(t *testing.T) {
	putFile(t, "/dav/p/storage/e2e-head.txt", []byte("head me"))
	resp := do(t, http.MethodHead, "/dav/p/storage/e2e-head.txt", nil)
	require.Equal(t, http.StatusOK, resp.StatusCode, "HEAD file: %s", getBody(t, resp))
	// HEAD must not return a body; resp.Body is already empty, but read it to
	// confirm (io.ReadAll on an empty body returns empty, no error).
	assert.Empty(t, getBody(t, resp), "HEAD must not return a body")
}

func TestE2E_OPTIONS_file(t *testing.T) {
	putFile(t, "/dav/p/storage/e2e-opt.txt", []byte("x"))
	resp := do(t, http.MethodOptions, "/dav/p/storage/e2e-opt.txt", nil)
	// OPTIONS on an existing resource should be 200 with an Allow header.
	require.Equal(t, http.StatusOK, resp.StatusCode, "OPTIONS file: %s", getBody(t, resp))
	allow := resp.Header.Get("Allow")
	assert.NotEmpty(t, allow, "OPTIONS must return an Allow header")
	t.Logf("OPTIONS Allow: %s", allow)
}

func TestE2E_OPTIONS_nonexistent(t *testing.T) {
	// The webdav_client library sends an OPTIONS before every PUT/GET; a 405
	// here would propagate to the client as the request error the phone saw.
	resp := do(t, http.MethodOptions, "/dav/p/storage/never-existed.txt", nil)
	assert.True(t, resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusNotFound,
		"OPTIONS on a nonexistent file should be 200 or 404, got %d (body=%s)", resp.StatusCode, getBody(t, resp))
}

func TestE2E_MKCOL_dir(t *testing.T) {
	resp := do(t, "MKCOL", "/dav/p/storage/e2e-dir", nil)
	require.Equal(t, http.StatusCreated, resp.StatusCode, "MKCOL new dir: %s", getBody(t, resp))
	st, err := os.Stat(filepath.Join(providerDir, "e2e-dir"))
	require.NoError(t, err)
	assert.True(t, st.IsDir())
}

func TestE2E_MKCOL_existing_dir(t *testing.T) {
	do(t, "MKCOL", "/dav/p/storage/e2e-dir2", nil)
	resp := do(t, "MKCOL", "/dav/p/storage/e2e-dir2", nil)
	// 405 Method Not Allowed is the WebDAV convention for "collection already
	// exists" - webdav_client relies on this to treat MKCOL as mkdirAll.
	assert.Equal(t, http.StatusMethodNotAllowed, resp.StatusCode,
		"MKCOL existing dir should be 405, got %d (body=%s)", resp.StatusCode, getBody(t, resp))
}

func TestE2E_MKCOL_nested(t *testing.T) {
	// webdav_client's mkdirAll does a top-level MKCOL, falls back to a
	// 409 -> per-segment walk. A nested path whose parents do not exist
	// exercises both.
	resp := do(t, "MKCOL", "/dav/p/storage/e2e-nest/a/b/c", nil)
	// Some servers 409 (conflict) for a deep MKCOL whose parent is missing;
	// either 201 (created the whole chain) or 409 is acceptable for this
	// assertion, what matters is that mkdirAll subsequently succeeds.
	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusConflict {
		t.Fatalf("MKCOL nested (no parent): want 201/409, got %d (body=%s)", resp.StatusCode, getBody(t, resp))
	}
}

func TestE2E_PUT_into_missing_dir(t *testing.T) {
	// The phone's upload path: PUT straight to /storage/Benni/Photos/Pixel 10/file
	// where the intermediate dirs do not exist yet. webdav_client's
	// wdWriteWithBytes calls mkdirAll on the parent first, then PUTs. This is
	// the exact scenario the backend log showed failing.
	resp := putFile(t, "/dav/p/storage/Benni/Photos/Pixel 10/PXL_e2e.jpg", []byte("pixel"))
	if resp.StatusCode != http.StatusCreated && resp.StatusCode != http.StatusNoContent {
		t.Fatalf("PUT into missing dir: want 201/204, got %d (body=%s)", resp.StatusCode, getBody(t, resp))
	}
	disk, err := os.ReadFile(filepath.Join(providerDir, "Benni/Photos/Pixel 10/PXL_e2e.jpg"))
	require.NoError(t, err)
	assert.Equal(t, "pixel", string(disk))
}

// TestE2E_PUT_phone_upload_sequence mirrors the EXACT sequence the
// seraph_app's HeadlessWebDavBackend + webdav_client wdWriteWithBytes drive
// for a gallery upload: an OPTIONS preflight on the file, then mkdirAll on
// the parent collection, then the PUT. This is what the phone's background
// backup does, and what the backend log showed returning 405. If the bare
// PUT_into_missing_dir test fails but THIS one passes, the bug is the
// server not creating the parent itself (a client mkdirAll dependency);
// if THIS one fails too, the bug is deeper in the staging/mkdirAll
// interaction.
func TestE2E_PUT_phone_upload_sequence(t *testing.T) {
	const file = "/dav/p/storage/Phone/Photos/Pixel 10/IMG_e2e.jpg"

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
	parent := strings.TrimSuffix(strings.TrimSuffix(file, "/"), "/IMG_e2e.jpg") + "/"
	parentRel := strings.TrimPrefix(parent, davBase) // "/storage/Phone/Photos/Pixel 10/"
	mkResp := do(t, "MKCOL", parent, nil)
	if mkResp.StatusCode != http.StatusCreated && mkResp.StatusCode != http.StatusMethodNotAllowed {
		if mkResp.StatusCode == http.StatusConflict {
			// 409 -> walk each segment, MKCOL'd relative to /dav/p.
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
	disk, err := os.ReadFile(filepath.Join(providerDir, "Phone/Photos/Pixel 10/IMG_e2e.jpg"))
	require.NoError(t, err)
	assert.Equal(t, "pixel", string(disk))
}

func TestE2E_PROPFIND_file(t *testing.T) {
	putFile(t, "/dav/p/storage/e2e-propfind.txt", []byte("prop me"))
	resp := do(t, "PROPFIND", "/dav/p/storage/e2e-propfind.txt", strings.NewReader(propfindBody), "Depth", "0", "Content-Type", "application/xml")
	require.Equal(t, http.StatusMultiStatus, resp.StatusCode, "PROPFIND file: %s", getBody(t, resp))
}

func TestE2E_PROPFIND_dir(t *testing.T) {
	do(t, "MKCOL", "/dav/p/storage/e2e-pfdir", nil)
	putFile(t, "/dav/p/storage/e2e-pfdir/inner.txt", []byte("inner"))
	resp := do(t, "PROPFIND", "/dav/p/storage/e2e-pfdir", strings.NewReader(propfindBody), "Depth", "1", "Content-Type", "application/xml")
	require.Equal(t, http.StatusMultiStatus, resp.StatusCode, "PROPFIND dir: %s", getBody(t, resp))
}

func TestE2E_PROPFIND_nonexistent(t *testing.T) {
	resp := do(t, "PROPFIND", "/dav/p/storage/no-such-file.txt", strings.NewReader(propfindBody), "Depth", "0", "Content-Type", "application/xml")
	// 404 Not Found is the correct response for PROPFIND on a missing resource.
	assert.Equal(t, http.StatusNotFound, resp.StatusCode,
		"PROPFIND nonexistent: want 404, got %d (body=%s)", resp.StatusCode, getBody(t, resp))
}

func TestE2E_DELETE_file(t *testing.T) {
	putFile(t, "/dav/p/storage/e2e-del.txt", []byte("delete me"))
	resp := do(t, http.MethodDelete, "/dav/p/storage/e2e-del.txt", nil)
	require.Equal(t, http.StatusNoContent, resp.StatusCode, "DELETE file: %s", getBody(t, resp))
	_, err := os.Stat(filepath.Join(providerDir, "e2e-del.txt"))
	assert.True(t, os.IsNotExist(err), "file should be gone on disk")
}

func TestE2E_DELETE_empty_dir(t *testing.T) {
	do(t, "MKCOL", "/dav/p/storage/e2e-emptydir", nil)
	resp := do(t, http.MethodDelete, "/dav/p/storage/e2e-emptydir", nil)
	require.Equal(t, http.StatusNoContent, resp.StatusCode, "DELETE empty dir: %s", getBody(t, resp))
	_, err := os.Stat(filepath.Join(providerDir, "e2e-emptydir"))
	assert.True(t, os.IsNotExist(err), "empty dir should be gone on disk")
}

func TestE2E_DELETE_nonempty_dir_recursive(t *testing.T) {
	do(t, "MKCOL", "/dav/p/storage/e2e-recdir", nil)
	putFile(t, "/dav/p/storage/e2e-recdir/a.txt", []byte("a"))
	do(t, "MKCOL", "/dav/p/storage/e2e-recdir/sub", nil)
	putFile(t, "/dav/p/storage/e2e-recdir/sub/b.txt", []byte("b"))
	resp := do(t, http.MethodDelete, "/dav/p/storage/e2e-recdir", nil)
	require.Equal(t, http.StatusNoContent, resp.StatusCode, "DELETE non-empty dir: %s", getBody(t, resp))
	_, err := os.Stat(filepath.Join(providerDir, "e2e-recdir"))
	assert.True(t, os.IsNotExist(err), "non-empty dir should be gone recursively")
}

func TestE2E_MOVE_rename_file(t *testing.T) {
	putFile(t, "/dav/p/storage/e2e-mov-src.txt", []byte("move me"))
	resp := do(t, "MOVE", "/dav/p/storage/e2e-mov-src.txt", nil, "Destination", gatewayBase+"/dav/p/storage/e2e-mov-dst.txt")
	require.Equal(t, http.StatusCreated, resp.StatusCode, "MOVE rename file: %s", getBody(t, resp))
	disk, err := os.ReadFile(filepath.Join(providerDir, "e2e-mov-dst.txt"))
	require.NoError(t, err)
	assert.Equal(t, "move me", string(disk))
	_, err = os.Stat(filepath.Join(providerDir, "e2e-mov-src.txt"))
	assert.True(t, os.IsNotExist(err), "source should be gone after MOVE")
}

func TestE2E_COPY_file(t *testing.T) {
	putFile(t, "/dav/p/storage/e2e-cpy-src.txt", []byte("copy me"))
	resp := do(t, "COPY", "/dav/p/storage/e2e-cpy-src.txt", nil, "Destination", gatewayBase+"/dav/p/storage/e2e-cpy-dst.txt")
	require.Equal(t, http.StatusCreated, resp.StatusCode, "COPY file: %s", getBody(t, resp))
	disk, err := os.ReadFile(filepath.Join(providerDir, "e2e-cpy-dst.txt"))
	require.NoError(t, err)
	assert.Equal(t, "copy me", string(disk))
	// source still present after COPY
	_, err = os.Stat(filepath.Join(providerDir, "e2e-cpy-src.txt"))
	assert.NoError(t, err, "source should still exist after COPY")
}

func TestE2E_PUT_atomic_no_partial_on_abort(t *testing.T) {
	// The atomic-PUT decorator must leave NOTHING at the destination if the
	// upload body is truncated. Simulate a dropped upload by opening a raw
	// TCP connection, sending a PUT with a Content-Length that overstates the
	// body, then closing the connection mid-stream - the server sees the
	// body never reach EOF and must treat the upload as aborted.
	conn, err := net.Dial("tcp", gatewayAddr)
	require.NoError(t, err)
	t.Cleanup(func() { conn.Close() })
	const file = "/dav/p/storage/e2e-abort.bin"
	const claimedLen = 1024 * 1024 // claim 1 MiB
	reqStr := "PUT " + file + " HTTP/1.1\r\n" +
		"Host: " + gatewayAddr + "\r\n" +
		"Content-Length: " + fmt.Sprintf("%d", claimedLen) + "\r\n" +
		"Connection: close\r\n\r\n" +
		"only-a-few-bytes" // far less than claimedLen; then we hang up
	_, err = conn.Write([]byte(reqStr))
	require.NoError(t, err)
	// Close (FIN) immediately after the short body: the server's io.Copy gets
	// an unexpected EOF rather than the full Content-Length, so trackingBody
	// records an incomplete read and Close() discards the staging file.
	conn.Close()

	// Give the server a moment to process the aborted request.
	time.Sleep(200 * time.Millisecond)

	// No destination file should have been published.
	_, err = os.Stat(filepath.Join(providerDir, "e2e-abort.bin"))
	assert.True(t, os.IsNotExist(err), "destination must not exist after an aborted PUT, got err=%v", err)
	// And no staging file should be left behind in the dir.
	files, err := os.ReadDir(providerDir)
	require.NoError(t, err)
	for _, f := range files {
		name := f.Name()
		if strings.HasPrefix(name, ".seraph-upload-") && strings.HasSuffix(name, ".part") {
			t.Errorf("leftover staging file after abort: %s", name)
		}
	}
}

// propfindBody is a minimal PROPFIND request body asking for the basic
// properties; golang.org/x/net/webdav accepts an empty body too, but sending
// this matches what real clients (webdav_client.readProps) send.
const propfindBody = `<?xml version="1.0" encoding="utf-8"?>
<D:propfind xmlns:D="DAV:">
  <D:allprop/>
</D:propfind>`
