package servicediscovery

import (
	"log/slog"
	"slices"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"go.uber.org/fx"
	"umbasa.net/seraph/logging"
	"umbasa.net/seraph/tracing"
)

const AnnouncementTopic = "seraph.service.announcement"
const InquiryTopic = "seraph.service.inquiry"
const HeartbeatTopic = "seraph.service.heartbeat"

type AnnouncementType string

const AnnouncementTypeAnnounce AnnouncementType = "ANNOUNCE"
const AnnouncementTypeRemove AnnouncementType = "REMOVE"

const DefaultHeartbeatInterval = 30

var Module = fx.Module("servicediscovery",
	fx.Provide(
		New,
	),
)

type Params struct {
	fx.In

	Log     *logging.Logger
	Tracing *tracing.Tracing
	Nc      *nats.Conn
	Lc      fx.Lifecycle
}

type Result struct {
	fx.Out

	ServiceDiscovery ServiceDiscovery
}

type ServiceDiscovery interface {
	Get(serviceType string) []*ServiceAnnouncement
	Listen(serviceType string) ServiceListener

	AnnounceService(serviceType string, properties map[string]string) LocalService
}

type ServiceListener interface {
	Services() <-chan *ServiceAnnouncement
	Close()
}

type LocalService interface {
	InstanceId() string
	Update(properties map[string]string)
	Remove()
}

type serviceDiscovery struct {
	mu sync.Mutex

	nc  *nats.Conn
	log *slog.Logger

	subscriptions []*nats.Subscription
	listeners     []*serviceListener

	byInstanceId  map[string]*remoteService
	byServiceType map[string][]*remoteService

	localServices map[string]*localService
}

type remoteService struct {
	announcement ServiceAnnouncement

	lastHearbeat time.Time
}

type localService struct {
	sd           *serviceDiscovery
	announcement ServiceAnnouncement
}

type serviceListener struct {
	sd          *serviceDiscovery
	updateChan  chan *ServiceAnnouncement
	cancelChan  chan struct{}
	serviceType string
}

func New(p Params) (Result, error) {
	discovery := &serviceDiscovery{
		nc:            p.Nc,
		log:           p.Log.GetLogger("discovery"),
		subscriptions: make([]*nats.Subscription, 0),
		listeners:     make([]*serviceListener, 0),
		byInstanceId:  make(map[string]*remoteService),
		byServiceType: make(map[string][]*remoteService),
		localServices: make(map[string]*localService),
	}

	p.Lc.Append(fx.StartHook(discovery.start))
	p.Lc.Append(fx.StartHook(discovery.stop))

	return Result{
		ServiceDiscovery: discovery,
	}, nil
}

func (sd *serviceDiscovery) start() error {
	sd.subscriptions = make([]*nats.Subscription, 0)

	sub, err := sd.nc.Subscribe(AnnouncementTopic, func(msg *nats.Msg) {
		announcement := ServiceAnnouncement{}

		err := announcement.Unmarshal(msg.Data)
		if err != nil {
			sd.log.Error("invalid Announcement", "error", err)
			return
		}

		sd.handleAnnouncement(announcement)
	})
	if err != nil {
		return err
	}
	sd.subscriptions = append(sd.subscriptions, sub)

	sub, err = sd.nc.Subscribe(InquiryTopic, func(msg *nats.Msg) {
		inquiry := ServiceInquiry{}

		err := inquiry.Unmarshal(msg.Data)
		if err != nil {
			sd.log.Error("invalid Inquiry", "error", err)
			return
		}

		sd.handleInquiry(inquiry)
	})
	if err != nil {
		return err
	}
	sd.subscriptions = append(sd.subscriptions, sub)

	sub, err = sd.nc.Subscribe(HeartbeatTopic, func(msg *nats.Msg) {
		heartbeat := ServiceHeartbeat{}

		err := heartbeat.Unmarshal(msg.Data)
		if err != nil {
			sd.log.Error("invalid Heartbeat", "error", err)
			return
		}

		sd.handleHeartbeat(heartbeat)
	})
	if err != nil {
		return err
	}
	sd.subscriptions = append(sd.subscriptions, sub)

	return nil
}

func (sd *serviceDiscovery) stop() error {
	for _, sub := range sd.subscriptions {
		err := sub.Unsubscribe()
		if err != nil {
			return err
		}
	}
	for _, listener := range sd.listeners {
		close(listener.cancelChan)
		close(listener.updateChan)
	}
	return nil
}

func (sd *serviceDiscovery) announce(service *localService, announcementType AnnouncementType) error {
	announcement := service.announcement
	announcement.AnnouncementType = string(announcementType)

	data, err := announcement.Marshal()
	if err != nil {
		return err
	}

	return sd.nc.Publish(AnnouncementTopic, data)
}

func (sd *serviceDiscovery) handleAnnouncement(announcement ServiceAnnouncement) {
	sd.mu.Lock()
	defer sd.mu.Unlock()

	sd.byInstanceId[announcement.InstanceID] = &remoteService{
		announcement: announcement,
		lastHearbeat: time.Now(),
	}
	byServiceType := sd.byServiceType[announcement.ServiceType]
	if byServiceType == nil {
		byServiceType = make([]*remoteService, 0)
		sd.byServiceType[announcement.ServiceType] = byServiceType
	}

	index := slices.IndexFunc(byServiceType, func(s *remoteService) bool {
		return s.announcement.InstanceID == announcement.InstanceID
	})

	if announcement.AnnouncementType == string(AnnouncementTypeRemove) {
		if index >= 0 {
			byServiceType = slices.Delete(byServiceType, index, 1)
			sd.byServiceType[announcement.ServiceType] = byServiceType
		}
	} else {
		if index >= 0 {
			byServiceType[index].announcement = announcement
			byServiceType[index].lastHearbeat = time.Now()
		} else {
			byServiceType = append(byServiceType, &remoteService{
				announcement: announcement,
				lastHearbeat: time.Now(),
			})
			sd.byServiceType[announcement.ServiceType] = byServiceType
		}
	}

	for _, listener := range sd.listeners {
		if listener.serviceType == announcement.ServiceType {
			select {
			case listener.updateChan <- &announcement:
			case <-listener.cancelChan:
			}
		}
	}
}

func (sd *serviceDiscovery) handleInquiry(inquiry ServiceInquiry) {
	sd.mu.Lock()
	defer sd.mu.Unlock()

	for _, service := range sd.localServices {
		if inquiry.ServiceType == "" || inquiry.ServiceType == service.announcement.ServiceType {
			sd.announce(service, AnnouncementTypeAnnounce)
		}
	}
}

func (sd *serviceDiscovery) handleHeartbeat(heartbeat ServiceHeartbeat) {
	sd.mu.Lock()
	defer sd.mu.Unlock()

	for _, service := range sd.byInstanceId {
		if service.announcement.InstanceID == heartbeat.InstanceID {
			service.lastHearbeat = time.Now()
		}
	}
}

func (sd *serviceDiscovery) Get(serviceType string) []*ServiceAnnouncement {
	sd.mu.Lock()
	defer sd.mu.Unlock()

	services := sd.byServiceType[serviceType]

	announcements := make([]*ServiceAnnouncement, 0, len(services))

	for _, service := range services {
		announcements = append(announcements, &service.announcement)
	}

	return announcements
}

func (sd *serviceDiscovery) Listen(serviceType string) ServiceListener {
	sd.mu.Lock()
	defer sd.mu.Unlock()

	listener := &serviceListener{
		sd:          sd,
		updateChan:  make(chan *ServiceAnnouncement),
		cancelChan:  make(chan struct{}),
		serviceType: serviceType,
	}

	sd.listeners = append(sd.listeners, listener)

	return listener
}

func (sd *serviceDiscovery) AnnounceService(serviceType string, properties map[string]string) LocalService {
	sd.mu.Lock()
	defer sd.mu.Unlock()

	service := &localService{
		sd: sd,
		announcement: ServiceAnnouncement{
			ServiceType:       serviceType,
			Properties:        properties,
			HeartbeatInterval: DefaultHeartbeatInterval,
			InstanceID:        uuid.NewString(),
		},
	}

	sd.localServices[service.announcement.InstanceID] = service

	sd.announce(service, AnnouncementTypeAnnounce)

	return service
}

func (ls *localService) InstanceId() string {
	return ls.announcement.InstanceID
}

func (ls *localService) Update(properties map[string]string) {
	ls.announcement.Properties = properties

	ls.sd.announce(ls, AnnouncementTypeAnnounce)
}

func (ls *localService) Remove() {
	ls.sd.mu.Lock()
	defer ls.sd.mu.Unlock()

	delete(ls.sd.localServices, ls.announcement.InstanceID)

	ls.sd.announce(ls, AnnouncementTypeRemove)
}

func (sl *serviceListener) Services() <-chan *ServiceAnnouncement {
	return sl.updateChan
}

func (sl *serviceListener) Close() {
	sl.sd.mu.Lock()
	defer sl.sd.mu.Unlock()

	index := slices.Index(sl.sd.listeners, sl)
	if index >= 0 {
		sl.sd.listeners = slices.Delete(slices.Clone(sl.sd.listeners), index, index+1)
	}

	close(sl.cancelChan)
	close(sl.updateChan)
}
