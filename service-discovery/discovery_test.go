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

	// wait for the initial service inquiry before announcing any services as otherwise this will interfere with the test
	time.Sleep(1 * time.Second)

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

func TestListenGet(t *testing.T) {
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

	listener := discovery.Listen("")
	defer listener.Close()

	announcement := ServiceAnnouncement{
		AnnouncementType:  string(AnnouncementTypeAnnounce),
		ServiceType:       "myService",
		InstanceID:        "foo",
		HeartbeatInterval: 5,
		Properties: map[string]string{
			"someProp": "someValue",
		},
	}

	data, err := announcement.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	nc.Publish(AnnouncementTopic, data)
	nc.Flush()

	var listenAnnouncement *ServiceAnnouncement
	select {
	case listenAnnouncement = <-listener.Services():
	case <-time.After(10 * time.Second):
		t.Fatal("no response from listener")
	}
	assert.Equal(t, &announcement, listenAnnouncement)

	gotAnnouncements := discovery.Get("")
	assert.Equal(t, 1, len(gotAnnouncements))
	assert.Equal(t, &announcement, gotAnnouncements[0])

	gotAnnouncements = discovery.Get("myService")
	assert.Equal(t, 1, len(gotAnnouncements))
	assert.Equal(t, &announcement, gotAnnouncements[0])

	listener2 := discovery.Listen("myService")
	defer listener2.Close()

	select {
	case listenAnnouncement = <-listener2.Services():
	case <-time.After(10 * time.Second):
		t.Fatal("no response from listener")
	}
	assert.Equal(t, &announcement, listenAnnouncement)

	announcement2 := ServiceAnnouncement{
		AnnouncementType:  string(AnnouncementTypeAnnounce),
		ServiceType:       "myService",
		InstanceID:        "bar",
		HeartbeatInterval: 6,
		Properties: map[string]string{
			"someOtherProp": "someOtherValue",
		},
	}

	data, err = announcement2.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	nc.Publish(AnnouncementTopic, data)
	nc.Flush()

	select {
	case listenAnnouncement = <-listener.Services():
	case <-time.After(10 * time.Second):
		t.Fatal("no response from listener")
	}
	assert.Equal(t, &announcement2, listenAnnouncement)

	select {
	case listenAnnouncement = <-listener2.Services():
	case <-time.After(10 * time.Second):
		t.Fatal("no response from listener")
	}
	assert.Equal(t, &announcement2, listenAnnouncement)

	gotAnnouncements = discovery.Get("")
	assert.Equal(t, 2, len(gotAnnouncements))
	assert.Contains(t, gotAnnouncements, &announcement)
	assert.Contains(t, gotAnnouncements, &announcement2)

	gotAnnouncements = discovery.Get("myService")
	assert.Equal(t, 2, len(gotAnnouncements))
	assert.Contains(t, gotAnnouncements, &announcement)
	assert.Contains(t, gotAnnouncements, &announcement2)

	announcement3 := ServiceAnnouncement{
		AnnouncementType:  string(AnnouncementTypeAnnounce),
		ServiceType:       "myOtherService",
		InstanceID:        "baz",
		HeartbeatInterval: 6,
		Properties:        map[string]string{},
	}

	data, err = announcement3.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	nc.Publish(AnnouncementTopic, data)
	nc.Flush()

	select {
	case listenAnnouncement = <-listener.Services():
	case <-time.After(10 * time.Second):
		t.Fatal("no response from listener")
	}
	assert.Equal(t, &announcement3, listenAnnouncement)

	assert.Equal(t, 0, len(listener2.Services()))

	gotAnnouncements = discovery.Get("")
	assert.Equal(t, 3, len(gotAnnouncements))
	assert.Contains(t, gotAnnouncements, &announcement)
	assert.Contains(t, gotAnnouncements, &announcement2)
	assert.Contains(t, gotAnnouncements, &announcement3)

	gotAnnouncements = discovery.Get("myService")
	assert.Equal(t, 2, len(gotAnnouncements))
	assert.Contains(t, gotAnnouncements, &announcement)
	assert.Contains(t, gotAnnouncements, &announcement2)

	gotAnnouncements = discovery.Get("myOtherService")
	assert.Equal(t, 1, len(gotAnnouncements))
	assert.Contains(t, gotAnnouncements, &announcement3)

	removal := ServiceAnnouncement{
		AnnouncementType: string(AnnouncementTypeRemove),
		InstanceID:       "foo",
		Properties:       map[string]string{},
	}

	data, err = removal.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	nc.Publish(AnnouncementTopic, data)
	nc.Flush()

	select {
	case listenAnnouncement = <-listener.Services():
	case <-time.After(10 * time.Second):
		t.Fatal("no response from listener")
	}
	assert.Equal(t, &removal, listenAnnouncement)

	select {
	case listenAnnouncement = <-listener2.Services():
	case <-time.After(10 * time.Second):
		t.Fatal("no response from listener")
	}
	assert.Equal(t, &removal, listenAnnouncement)

	gotAnnouncements = discovery.Get("")
	assert.Equal(t, 2, len(gotAnnouncements))
	assert.Contains(t, gotAnnouncements, &announcement2)
	assert.Contains(t, gotAnnouncements, &announcement3)

	gotAnnouncements = discovery.Get("myService")
	assert.Equal(t, 1, len(gotAnnouncements))
	assert.Contains(t, gotAnnouncements, &announcement2)

	gotAnnouncements = discovery.Get("myOtherService")
	assert.Equal(t, 1, len(gotAnnouncements))
	assert.Contains(t, gotAnnouncements, &announcement3)

	removal2 := ServiceAnnouncement{
		AnnouncementType: string(AnnouncementTypeRemove),
		InstanceID:       "foo",
		Properties:       map[string]string{},
	}

	data, err = removal2.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	nc.Publish(AnnouncementTopic, data)
	nc.Flush()

	assert.Equal(t, 0, len(listener.Services()))
	assert.Equal(t, 0, len(listener2.Services()))

	gotAnnouncements = discovery.Get("")
	assert.Equal(t, 2, len(gotAnnouncements))
	assert.Contains(t, gotAnnouncements, &announcement2)
	assert.Contains(t, gotAnnouncements, &announcement3)

	gotAnnouncements = discovery.Get("myService")
	assert.Equal(t, 1, len(gotAnnouncements))
	assert.Contains(t, gotAnnouncements, &announcement2)

	gotAnnouncements = discovery.Get("myOtherService")
	assert.Equal(t, 1, len(gotAnnouncements))
	assert.Contains(t, gotAnnouncements, &announcement3)

	removal3 := ServiceAnnouncement{
		AnnouncementType: string(AnnouncementTypeRemove),
		InstanceID:       "bar",
		Properties:       map[string]string{},
	}

	data, err = removal3.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	nc.Publish(AnnouncementTopic, data)
	nc.Flush()

	select {
	case listenAnnouncement = <-listener.Services():
	case <-time.After(10 * time.Second):
		t.Fatal("no response from listener")
	}
	assert.Equal(t, &removal3, listenAnnouncement)

	select {
	case listenAnnouncement = <-listener2.Services():
	case <-time.After(10 * time.Second):
		t.Fatal("no response from listener")
	}
	assert.Equal(t, &removal3, listenAnnouncement)

	gotAnnouncements = discovery.Get("")
	assert.Equal(t, 1, len(gotAnnouncements))
	assert.Contains(t, gotAnnouncements, &announcement3)

	gotAnnouncements = discovery.Get("myService")
	assert.Equal(t, 0, len(gotAnnouncements))

	gotAnnouncements = discovery.Get("myOtherService")
	assert.Equal(t, 1, len(gotAnnouncements))
	assert.Contains(t, gotAnnouncements, &announcement3)

	removal4 := ServiceAnnouncement{
		AnnouncementType: string(AnnouncementTypeRemove),
		InstanceID:       "baz",
		Properties:       map[string]string{},
	}

	data, err = removal4.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	nc.Publish(AnnouncementTopic, data)
	nc.Flush()

	select {
	case listenAnnouncement = <-listener.Services():
	case <-time.After(10 * time.Second):
		t.Fatal("no response from listener")
	}
	assert.Equal(t, &removal4, listenAnnouncement)

	assert.Equal(t, 0, len(listener2.Services()))

	gotAnnouncements = discovery.Get("")
	assert.Equal(t, 0, len(gotAnnouncements))

	gotAnnouncements = discovery.Get("myService")
	assert.Equal(t, 0, len(gotAnnouncements))

	gotAnnouncements = discovery.Get("myOtherService")
	assert.Equal(t, 0, len(gotAnnouncements))
}

func TestInquiryOnStart(t *testing.T) {
	nc, err := nats.Connect(natsServer.ClientURL())
	if err != nil {
		t.Fatal(err)
	}

	_, lc, err := getDiscovery(t, nc)
	if err != nil {
		t.Fatal(err)
	}

	c := make(chan *nats.Msg, 1)
	sub, err := nc.ChanSubscribe(InquiryTopic, c)
	if err != nil {
		t.Fatal(err)
	}
	defer sub.Unsubscribe()

	lc.Start(context.Background())
	defer lc.Stop(context.Background())

	inquiry := ServiceInquiry{}
	receive(t, c, &inquiry)

	assert.Equal(t, "", inquiry.ServiceType)
	assert.Equal(t, "", inquiry.InstanceID)
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
