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

package search

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/spf13/viper"
	"github.com/stretchr/testify/assert"
	"umbasa.net/seraph/api-gateway/auth"
	"umbasa.net/seraph/events"
	"umbasa.net/seraph/logging"
)

var natsServer *server.Server

func TestMain(m *testing.M) {
	gin.SetMode(gin.TestMode)
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
}

func shutdown() {
	if natsServer != nil {
		natsServer.Shutdown()
		natsServer = nil
	}
}

func TestSearchStreamsReplies(t *testing.T) {
	setSearchTimeouts(t, 20*time.Millisecond, 100*time.Millisecond)

	nc := connectNats(t)
	defer nc.Close()

	app := newSearchApp(t, nc)
	server := httptest.NewServer(app)
	defer server.Close()

	requestChan := make(chan *nats.Msg, 1)
	sub, err := nc.ChanSubscribe(events.SearchRequestTopic, requestChan)
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Unsubscribe()

	errCh := respondToSearchRequest(requestChan, func(req events.SearchRequest) error {
		if req.Query != "hello" {
			return errors.New("unexpected query")
		}
		if req.UserId != "anonymous" {
			return errors.New("unexpected user id")
		}
		if len(req.Types) != 1 || req.Types[0] != events.SearchTypeFiles {
			return errors.New("unexpected search types")
		}

		ack := events.SearchAck{
			RequestId: req.RequestId,
			ReplyId:   "provider-1",
			Ack:       true,
			Types:     []string{events.SearchTypeFiles},
		}
		if err := publishJSON(nc, ackTopic(req.RequestId), &ack); err != nil {
			return err
		}

		reply1 := events.SearchReply{
			RequestId: req.RequestId,
			ReplyId:   "provider-1",
			Type:      events.SearchTypeFiles,
			Reply: map[string]any{
				"id": "file-1",
			},
			Last: false,
		}
		if err := publishJSON(nc, replyTopic(req.RequestId), &reply1); err != nil {
			return err
		}

		reply2 := events.SearchReply{
			RequestId: req.RequestId,
			ReplyId:   "provider-1",
			Type:      events.SearchTypeFiles,
			Reply: map[string]any{
				"id": "file-2",
			},
			Last: false,
		}
		if err := publishJSON(nc, replyTopic(req.RequestId), &reply2); err != nil {
			return err
		}

		time.Sleep(searchAckTime + 5*time.Millisecond)

		lastReply := events.SearchReply{
			RequestId: req.RequestId,
			ReplyId:   "provider-1",
			Type:      events.SearchTypeFiles,
			Last:      true,
		}
		if err := publishJSON(nc, replyTopic(req.RequestId), &lastReply); err != nil {
			return err
		}

		return nc.Flush()
	})

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, server.URL+"/api/search?q=hello", nil)
	if err != nil {
		t.Fatal(err)
	}

	resp, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	assert.Equal(t, http.StatusOK, resp.StatusCode)
	assert.Contains(t, resp.Header.Get("Content-Type"), "text/event-stream")

	replies, err := readSSEReplies(resp.Body, 2)
	if err != nil {
		t.Fatal(err)
	}

	assert.Equal(t, 2, len(replies))
	if len(replies) == 2 {
		assert.Equal(t, "file-1", replies[0].Reply["id"])
		assert.Equal(t, "file-2", replies[1].Reply["id"])
	}

	if handlerErr := <-errCh; handlerErr != nil {
		t.Fatal(handlerErr)
	}
}

func TestSearchNoProviders(t *testing.T) {
	setSearchTimeouts(t, 20*time.Millisecond, 100*time.Millisecond)

	nc := connectNats(t)
	defer nc.Close()

	app := newSearchApp(t, nc)
	server := httptest.NewServer(app)
	defer server.Close()

	requestChan := make(chan *nats.Msg, 1)
	sub, err := nc.ChanSubscribe(events.SearchRequestTopic, requestChan)
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Unsubscribe()

	errCh := respondToSearchRequest(requestChan, func(req events.SearchRequest) error {
		if req.Query != "no-provider" {
			return errors.New("unexpected query")
		}
		return nil
	})

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, server.URL+"/api/search?q=no-provider", nil)
	if err != nil {
		t.Fatal(err)
	}

	resp, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	replies, err := readSSEReplies(resp.Body, 0)
	if err != nil {
		t.Fatal(err)
	}
	assert.Equal(t, 0, len(replies))

	if handlerErr := <-errCh; handlerErr != nil {
		t.Fatal(handlerErr)
	}
}

func TestSearchProviderAckNoReply(t *testing.T) {
	setSearchTimeouts(t, 20*time.Millisecond, 60*time.Millisecond)

	nc := connectNats(t)
	defer nc.Close()

	app := newSearchApp(t, nc)
	server := httptest.NewServer(app)
	defer server.Close()

	requestChan := make(chan *nats.Msg, 1)
	sub, err := nc.ChanSubscribe(events.SearchRequestTopic, requestChan)
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Unsubscribe()

	errCh := respondToSearchRequest(requestChan, func(req events.SearchRequest) error {
		ack := events.SearchAck{
			RequestId: req.RequestId,
			ReplyId:   "provider-timeout",
			Ack:       true,
			Types:     []string{events.SearchTypeFiles},
		}
		if err := publishJSON(nc, ackTopic(req.RequestId), &ack); err != nil {
			return err
		}
		return nc.Flush()
	})

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, server.URL+"/api/search?q=ack-only", nil)
	if err != nil {
		t.Fatal(err)
	}

	resp, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	replies, err := readSSEReplies(resp.Body, 0)
	if err != nil {
		t.Fatal(err)
	}
	assert.Equal(t, 0, len(replies))

	if handlerErr := <-errCh; handlerErr != nil {
		t.Fatal(handlerErr)
	}
}

func setSearchTimeouts(t *testing.T, ackTimeout time.Duration, replyTimeout time.Duration) {
	oldAck := searchAckTime
	oldReply := searchReplyTime
	searchAckTime = ackTimeout
	searchReplyTime = replyTimeout

	t.Cleanup(func() {
		searchAckTime = oldAck
		searchReplyTime = oldReply
	})
}

func connectNats(t *testing.T) *nats.Conn {
	t.Helper()
	nc, err := nats.Connect(natsServer.ClientURL())
	if err != nil {
		t.Fatal(err)
	}
	return nc
}

func newSearchApp(t *testing.T, nc *nats.Conn) *gin.Engine {
	t.Helper()
	logger := logging.New(logging.Params{})
	config := viper.New()
	config.Set("auth.enabled", false)

	authResult, err := auth.New(auth.Params{
		Log:   logger,
		Viper: config,
	})
	if err != nil {
		t.Fatal(err)
	}

	res := New(Params{
		Log:  logger,
		Nc:   nc,
		Auth: authResult.Auth,
	})

	app := gin.New()
	apiGroup := app.Group("/api")
	publicGroup := app.Group("/public")
	res.Handler.Setup(app, apiGroup, publicGroup)
	return app
}

func respondToSearchRequest(requestChan <-chan *nats.Msg, handler func(events.SearchRequest) error) <-chan error {
	errCh := make(chan error, 1)
	go func() {
		msg, err := waitForNatsMessage(requestChan, 2*time.Second)
		if err != nil {
			errCh <- err
			return
		}
		req := events.SearchRequest{}
		if err := json.Unmarshal(msg.Data, &req); err != nil {
			errCh <- err
			return
		}
		errCh <- handler(req)
	}()
	return errCh
}

func waitForNatsMessage(ch <-chan *nats.Msg, timeout time.Duration) (*nats.Msg, error) {
	select {
	case msg := <-ch:
		return msg, nil
	case <-time.After(timeout):
		return nil, errors.New("no nats message received")
	}
}

func publishJSON(nc *nats.Conn, topic string, payload any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	return nc.Publish(topic, data)
}

func ackTopic(requestId string) string {
	return fmt.Sprintf(events.SearchAckTopicPattern, requestId)
}

func replyTopic(requestId string) string {
	return fmt.Sprintf(events.SearchReplyTopicPattern, requestId)
}

func readSSEReplies(reader io.Reader, maxEvents int) ([]events.SearchReply, error) {
	scanner := bufio.NewReader(reader)
	replies := make([]events.SearchReply, 0)
	dataLines := make([]string, 0)

	for {
		line, err := scanner.ReadString('\n')
		if err != nil {
			if errors.Is(err, io.EOF) {
				return replies, nil
			}
			return replies, err
		}

		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			if len(dataLines) == 0 {
				continue
			}
			payload := strings.Join(dataLines, "\n")
			dataLines = dataLines[:0]

			reply := events.SearchReply{}
			if err := json.Unmarshal([]byte(payload), &reply); err != nil {
				return replies, err
			}
			replies = append(replies, reply)
			if maxEvents > 0 && len(replies) >= maxEvents {
				return replies, nil
			}
			continue
		}

		if strings.HasPrefix(line, "data:") {
			dataLines = append(dataLines, strings.TrimLeft(line[5:], " "))
		}
	}
}
