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

package fileprovider

import (
	"bytes"
	"context"
	"crypto/rand"
	"io"
	"log/slog"
	"os"
	"testing"

	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"golang.org/x/net/webdav"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/tracing"
)

func getClient(t *testing.T) (Client, *nats.Conn) {
	nc, err := nats.Connect(natsServer.ClientURL())
	if err != nil {
		t.Error(err)
		t.FailNow()
	}
	logger := logging.New(logging.Params{})
	logger.SetLevel(slog.LevelDebug)

	params := ServerParams{
		Logger:  logger,
		Tracing: tracing.NewNoopTracing(),
		Nc:      nc,
		Js:      nil,
	}

	fs := webdav.Dir(tmpDir)

	NewFileProviderServer(params, "testforclient", fs, false)

	client := NewFileProviderClient("testforclient", nc, logger)

	return client, nc
}

func TestClient(t *testing.T) {
	client, _ := getClient(t)

	t.Run("TestLargePayload", func(t *testing.T) {
		payload := make([]byte, 2048*1024)
		rand.Read(payload)

		file, err := client.OpenFile(context.Background(), "testfile", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0644)
		if err != nil {
			t.Fatal(err)
		}

		n, err := file.Write(payload)
		if err != nil {
			t.Error(err)
		}
		if n < len(payload) {
			t.Errorf("only %d bytes were written instead of %d", n, len(payload))
		}

		err = file.Close()
		if err != nil {
			t.Fatal(err)
		}

		file, err = client.OpenFile(context.Background(), "testfile", os.O_RDONLY, 0)
		if err != nil {
			t.Fatal(err)
		}

		payload2 := make([]byte, 2048*1024)
		n, err = file.Read(payload2)
		if err != nil {
			t.Error(err)
		}
		if n < len(payload2) {
			t.Errorf("only %d bytes were read instead of %d", n, len(payload2))
		}

		// use assert.True() instead of assert.Equals() to avoid printing the entire payload if the test fails
		assert.True(t, bytes.Equal(payload, payload2), "read payload did not match what was written")

		n, err = file.Read(payload2)
		assert.Equal(t, 0, n, "expected 0 bytes to be read")
		assert.ErrorIs(t, err, io.EOF, "expected EOF to be returned")

		err = file.Close()
		if err != nil {
			t.Fatal(err)
		}
	})
}
