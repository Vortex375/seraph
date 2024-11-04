package messaging

import (
	"reflect"
	"time"

	"github.com/nats-io/nats.go"
)

const DefaultTimeout = 30 * time.Second

type RequestPayload interface {
	Marshal() ([]byte, error)
}

type ResponsePayload interface {
	Unmarshal(b []byte) error
}

func Request[Req RequestPayload, Res ResponsePayload](nc *nats.Conn, topic string, req Req, res Res) error {
	return RequestTimeout[Req, Res](nc, topic, DefaultTimeout, req, res)
}

func RequestVoid[Req RequestPayload](nc *nats.Conn, topic string, req Req) error {
	var v ResponsePayload = nil
	return RequestTimeout(nc, topic, DefaultTimeout, req, v)
}

func RequestVoidTimeout[Req RequestPayload](nc *nats.Conn, topic string, timeout time.Duration, req Req) error {
	var v ResponsePayload = nil
	return RequestTimeout(nc, topic, timeout, req, v)
}

func RequestTimeout[Req RequestPayload, Res ResponsePayload](nc *nats.Conn, topic string, timeout time.Duration, req Req, res Res) error {
	data, _ := req.Marshal()

	msg, err := nc.Request(topic, data, timeout)

	if err != nil {
		return err
	}

	rv := reflect.ValueOf(res)
	if !rv.IsValid() || rv.IsNil() {
		return nil
	}

	err = res.Unmarshal(msg.Data)

	return err
}
