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

package e2e

// SMB-backed end-to-end WebDAV suite.
//
// The dir-provider suite (TestE2EDirProvider) covers the WebDAV verbs against
// a local-filesystem provider, but the production "storage" space the phone
// uploads to is backed by file-provider-smb (go-smb2 over a real SMB share).
// SMB has its own share-access semantics that the local FS does not - notably
// the STATUS_SHARING_VIOLATION ("share access flags incompatible") the phone's
// atomic-PUT staging rename hit - so this test runs the SAME verb suite against
// a real Samba server (the dockurr/samba image) serving a TEMPORARY host
// directory over a bind mount, with an in-process file-provider-smb server
// over the shared NATS, resolved through a second seeded space ("smbstorage").
//
// Everything the test writes lives under the bind-mounted temp dir, so the
// host's real files are untouched, and the assertions read straight off the
// host side of the bind mount (the same files the share is serving).

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"testing"
	"time"

	"github.com/moby/moby/api/types/container"
	"github.com/stretchr/testify/require"
	"go.uber.org/fx/fxtest"
	xwebdav "golang.org/x/net/webdav"
	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/file-provider-smb/smbprovider"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/tracing"

	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"
)

const (
	smbShareName    = "Data"
	smbUser         = "samba"
	smbPass         = "secret"
	smbSpaceProvId = "smbstorage"
	smbProviderId  = "smb-test-provider"
)

// TestE2ESmbProvider runs the full WebDAV verb suite against a real Samba
// server, fronted by file-provider-smb, resolved through a second seeded
// space. Skipped automatically when Docker is unavailable (the suite needs
// a testcontainer for the Samba server); the dir-provider suite does not
// need Docker for its own provider but shares the mongo container started in
// TestMain, so both run together when Docker is up.
func TestE2ESmbProvider(t *testing.T) {
	ctx := context.Background()

	// Host-side temp dir bind-mounted into the Samba container at /storage
	// (the share root the dockurr/samba image exports). The file-provider-smb's
	// pathPrefix is "/" (the share root), so WebDAV paths under
	// /dav/p/smbstorage/<x> map to <share>/<x> = <hostSmbDir>/<x> on the host -
	// so the suite's on-disk assertions read the same files directly.
	//
	// Created under $HOME rather than the OS temp dir: this test runs against
	// Rancher Desktop, which only bind-mounts paths inside its shared directory
	// (the user's home) into the container VM - a /tmp bind would silently
	// present an empty dir to the container, masking the host's files behind
	// the image's declared /storage VOLUME.
	hostSmbDir, err := os.MkdirTemp("/home/vortex", "seraph-e2e-smb-*")
	require.NoError(t, err)
	t.Cleanup(func() { os.RemoveAll(hostSmbDir) })

	// Start the Samba server. The dockurr/samba image exports the share named
	// by NAME over /storage, authenticating USER/PASS, on port 445.
	sambaC, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: testcontainers.ContainerRequest{
			Image: "dockurr/samba",
			Env: map[string]string{
				"NAME": smbShareName,
				"USER": smbUser,
				"PASS": smbPass,
			},
			ExposedPorts: []string{"445/tcp"},
			HostConfigModifier: func(hc *container.HostConfig) {
				hc.Binds = []string{hostSmbDir + ":/storage:rw"}
			},
			// smbd takes a couple of seconds to start. The image EXPOSEs 139
			// (NetBIOS) as well as 445, and ForExposedPort would wait on both,
			// but only 445 is published - so wait on a log line smbd emits once
			// it is ready to serve, rather than on a port.
			WaitingFor: wait.ForLog("smbd version").WithStartupTimeout(60 * time.Second),
		},
		Started: true,
	})
	require.NoError(t, err, "start samba container")
	t.Cleanup(func() { _ = testcontainers.TerminateContainer(sambaC) })

	// Ask for the 445 endpoint specifically: the image EXPOSEs 139 too, and
	// Endpoint("") returns the lowest-numbered bound port (139, not published),
	// which fails. PortEndpoint takes the exact port to resolve.
	smbEndpoint, err := sambaC.PortEndpoint(ctx, "445/tcp", "")
	require.NoError(t, err)
	t.Logf("samba endpoint: %s", smbEndpoint)

	// Give smbd a small grace period past port-listen for the share to be
	// fully exported; the port is up marginally before the share is browsable.
	// A retry loop on the first SMB operation would be cleaner, but the
	// file-provider-smb factory's init() connects eagerly, so a short sleep
	// here keeps the failure mode a clear "could not connect" rather than a
	// flaky first-verb error.
	time.Sleep(3 * time.Second)

	// In-process file-provider-smb over the shared NATS (started in TestMain).
	// The SmbFileSystem connects to the Samba container's endpoint; the
	// fileprovider server subscribes under smbProviderId, so the gateway's
	// delegating fs resolves the seeded "smbstorage" space onto it.
	logger := logging.New(logging.Params{})
	smbFs := smbprovider.NewSmbFileSystem(logger, smbEndpoint, smbShareName, smbUser, smbPass, "/")
	t.Cleanup(smbFs.Close)
	fpServer, err := fileprovider.NewFileProviderServer(fileprovider.ServerParams{
		Logger:  logger,
		Tracing: tracing.NewNoopTracing(),
		Nc:      fpConn, // the shared NATS conn from TestMain
		Js:      nil,
	}, smbProviderId, smbFs, false)
	require.NoError(t, err)
	require.NoError(t, fpServer.Start())
	t.Cleanup(func() { fpServer.Stop(true) })

	// Seed a second space pointing at the SMB provider, via the gateway's own
	// /api/spaces endpoint (the same path a real client uses). WebDAV paths
	// under /dav/p/smbstorage/<x> then resolve to <smbShareRoot>/<x> on the
	// share, i.e. <hostSmbDir>/<x> on the host.
	require.NoError(t, seedSpaceViaHttpSmb(), "seed smb space")

	// Run the same verb suite the dir provider runs, against the SMB backing
	// store. A provider-specific regression (e.g. the SMB share-access
	// violation on staging rename) shows up as a failed subtest here while the
	// dir suite stays green, localising it to the SMB path.
	runWebDavVerbSuite(t, hostSmbDir, "/dav/p/"+smbSpaceProvId)
}

// seedSpaceViaHttpSmb creates the "smbstorage" space pointing at the SMB
// file-provider, mirroring seedSpaceViaHttp for the dir space.
func seedSpaceViaHttpSmb() error {
	body := map[string]any{
		"title": "e2e smb space",
		"users": []string{"anonymous"},
		"fileProviders": []map[string]any{{
			"spaceProviderId": smbSpaceProvId,
			"providerId":      smbProviderId,
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

// keep these imports referenced even when the SMB test is skipped due to no Docker
var _ = fxtest.NewLifecycle
var _ xwebdav.FileSystem = xwebdav.Dir("")
