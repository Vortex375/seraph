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

package main

import (
	"encoding/json"
	"log"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"golang.org/x/net/webdav"

	"umbasa.net/seraph/file-provider/fileprovider"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/tracing"
)

const providerID = "testprovider"

type output struct {
	NatsURL    string `json:"nats_url"`
	ProviderID string `json:"provider_id"`
	TmpDir     string `json:"tmp_dir"`
}

func main() {
	jsDir, jsCleanup, err := initJetStreamDir()
	if err != nil {
		log.Printf("failed to init jetstream dir: %v", err)
		return
	}
	defer jsCleanup()

	opts := &server.Options{
		Port:      -1,
		JetStream: true,
		StoreDir:  jsDir,
		NoSigs:    true,
		NoLog:     true,
	}
	natsServer, err := server.NewServer(opts)
	if err != nil {
		log.Fatal(err)
	}

	natsServer.Start()
	defer natsServer.Shutdown()
	if !natsServer.ReadyForConnections(5 * time.Second) {
		log.Printf("nats server not ready")
		return
	}

	tmpDir, cleanupDir, err := initTmpDir()
	if err != nil {
		log.Printf("failed to init temp dir: %v", err)
		return
	}
	defer cleanupDir()

	nc, err := nats.Connect(natsServer.ClientURL())
	if err != nil {
		log.Printf("failed to connect to nats: %v", err)
		return
	}
	defer nc.Close()

	logger := logging.New(logging.Params{})
	logger.SetLevel(slog.LevelDebug)
	params := fileprovider.ServerParams{
		Logger:  logger,
		Tracing: tracing.NewNoopTracing(),
		Nc:      nc,
		Js:      nil,
	}

	fs := webdav.Dir(tmpDir)
	serverInstance, err := fileprovider.NewFileProviderServer(params, providerID, fs, false)
	if err != nil {
		log.Printf("failed to create file provider server: %v", err)
		return
	}

	if err := serverInstance.Start(); err != nil {
		log.Printf("failed to start file provider server: %v", err)
		return
	}
	defer func() {
		_ = serverInstance.Stop(true)
	}()

	out := output{
		NatsURL:    natsServer.ClientURL(),
		ProviderID: providerID,
		TmpDir:     tmpDir,
	}

	encoded, err := json.Marshal(out)
	if err != nil {
		log.Printf("failed to encode output: %v", err)
		return
	}

	_, _ = os.Stdout.Write(append(encoded, '\n'))

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
}

func initTmpDir() (string, func(), error) {
	if dir := os.Getenv("FILEPROVIDER_TEST_DIR"); dir != "" {
		return dir, func() {}, nil
	}

	dir, err := os.MkdirTemp("", "seraph-fileprovider-test-")
	if err != nil {
		return "", func() {}, err
	}

	return dir, func() {
		_ = os.RemoveAll(dir)
	}, nil
}

func initJetStreamDir() (string, func(), error) {
	dir, err := os.MkdirTemp("", "seraph-nats-js-")
	if err != nil {
		return "", func() {}, err
	}

	return dir, func() {
		_ = os.RemoveAll(dir)
	}, nil
}
