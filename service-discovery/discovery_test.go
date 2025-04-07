package servicediscovery

import (
	"context"
	"log/slog"
	"os"
	"testing"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/stretchr/testify/assert"
	"go.uber.org/fx/fxtest"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/messaging"
	"umbasa.net/seraph/tracing"
)

var natsServer *server.Server

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
}

func shutdown() {
	if natsServer != nil {
		natsServer.Shutdown()
		natsServer = nil
	}
}

func TestAnnounceUpdateRemove(t *testing.T) {
	nc, err := nats.Connect(natsServer.ClientURL())
	if err != nil {
		t.Fatal(err)
	}

	discovery, lc, err := getDiscovery(t, nc)
	if err != nil {
		t.Fatal(err)
	}

	lc.Start(context.Background())
	defer lc.Stop(context.Background())

	c := make(chan *nats.Msg, 1)
	sub, err := nc.ChanSubscribe(AnnouncementTopic, c)
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Unsubscribe()

	service := discovery.AnnounceService("myType", map[string]string{
		"someProp": "someValue",
	})

	announcement := ServiceAnnouncement{}
	receive(t, c, &announcement)

	assert.Equal(t, string(AnnouncementTypeAnnounce), announcement.AnnouncementType)
	assert.Equal(t, "myType", announcement.ServiceType)
	assert.Equal(t, map[string]string{"someProp": "someValue"}, announcement.Properties)
	assert.Equal(t, DefaultHeartbeatInterval, announcement.HeartbeatInterval)

	instanceId := announcement.InstanceID

	assert.Equal(t, instanceId, service.InstanceId())

	service.Update(map[string]string{
		"otherProp": "otherValue",
	})

	announcement = ServiceAnnouncement{}
	receive(t, c, &announcement)

	assert.Equal(t, instanceId, announcement.InstanceID)
	assert.Equal(t, string(AnnouncementTypeAnnounce), announcement.AnnouncementType)
	assert.Equal(t, "myType", announcement.ServiceType)
	assert.Equal(t, map[string]string{"otherProp": "otherValue"}, announcement.Properties)
	assert.Equal(t, DefaultHeartbeatInterval, announcement.HeartbeatInterval)

	service.Remove()

	announcement = ServiceAnnouncement{}
	receive(t, c, &announcement)

	assert.Equal(t, instanceId, announcement.InstanceID)
	assert.Equal(t, string(AnnouncementTypeRemove), announcement.AnnouncementType)
}

func getDiscovery(t *testing.T, nc *nats.Conn) (ServiceDiscovery, *fxtest.Lifecycle, error) {
	lc := fxtest.NewLifecycle(t)

	logger := logging.New(logging.Params{})
	logger.SetLevel(slog.LevelDebug)

	result, err := New(Params{
		Tracing: tracing.NewNoopTracing(),
		Log:     logger,
		Nc:      nc,
		Lc:      lc,
	})

	return result.ServiceDiscovery, lc, err
}

func receive[T messaging.ResponsePayload](t *testing.T, c chan *nats.Msg, res T) T {
	var msg *nats.Msg
	select {
	case msg = <-c:
	case <-time.After(10 * time.Second):
		t.Fatal("no message received")
	}
	err := res.Unmarshal(msg.Data)
	if err != nil {
		t.Fatal(err)
	}

	return res
}
