// Copyright © 2024 Benjamin Schmitz

// This file is part of Seraph.

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

package smbprovider

import (
	"errors"
	"net"
	"time"

	"github.com/hirochachacha/go-smb2"
	"umbasa.net/seraph/logging"
)

// time after which an idle SMB session is closed
const idleTimeout = 10 * time.Minute

type shareRequest int

const (
	shareRequestShutdown shareRequest = iota
	shareRequestGet
	shareRequestKeep
	shareRequestRefresh
)

type shareResult struct {
	session *smb2.Share
	err     error
}

type shareFactory struct {
	addr      string
	username  string
	password  string
	sharename string

	conn    net.Conn
	session *smb2.Session
	share   *smb2.Share

	reqShare chan shareRequest
	resShare chan shareResult

	log *logging.Logger
}

func (s *shareFactory) init() {
	log := s.log.GetLogger("smbprovider")
	s.reqShare = make(chan shareRequest)
	s.resShare = make(chan shareResult)

	go func() {
		for {
			req := <-s.reqShare

			if req == shareRequestShutdown {
				if s.session != nil {
					s.closeSession()
					log.Info("closed SMB session with "+s.addr, "addr", s.addr, "share", s.sharename, "reason", "shutdown")
				}
				close(s.resShare)
				return
			}

			if s.session == nil {
				err := s.openSession()
				if err != nil {
					log.Error("failed to open SMB session with "+s.addr, "addr", s.addr, "share", s.sharename, "username", s.username, "error", err)
					s.resShare <- shareResult{nil, err}
					continue
				}
				log.Info("opened SMB session with "+s.addr, "addr", s.addr, "share", s.sharename, "username", s.username)
			}

			if req == shareRequestGet || req == shareRequestRefresh {
				s.resShare <- shareResult{s.share, nil}
			}

			// session is now active - start session timeout
			timer := time.NewTimer(idleTimeout)

		haveSession:
			for {
				select {
				case req = <-s.reqShare:
					if req == shareRequestShutdown {
						if s.session != nil {
							s.closeSession()
							log.Info("closed SMB session with "+s.addr, "addr", s.addr, "share", s.sharename, "reason", "shutdown")
						}
						close(s.resShare)
						return
					}

					if req == shareRequestRefresh {
						if s.session != nil {
							s.closeSession()
							log.Info("closed SMB session with "+s.addr, "addr", s.addr, "share", s.sharename, "reason", "refresh")
						}
						err := s.openSession()
						if err != nil {
							log.Error("failed to open SMB session with "+s.addr, "addr", s.addr, "share", s.sharename, "username", s.username, "error", err)
							s.resShare <- shareResult{nil, err}
							break haveSession
						}
					}

					if req == shareRequestGet || req == shareRequestRefresh {
						s.resShare <- shareResult{s.share, nil}
					}

					if !timer.Stop() {
						<-timer.C
					}
					timer.Reset(idleTimeout)

				case <-timer.C:
					if s.session != nil {
						s.closeSession()
						log.Info("closed SMB session with "+s.addr, "addr", s.addr, "share", s.sharename, "reason", "idle")
					}
					break haveSession
				}
			}
		}
	}()
}

func (s *shareFactory) getShare() (*smb2.Share, error) {
	s.reqShare <- shareRequestGet
	result := <-s.resShare
	return result.session, result.err
}

func (s *shareFactory) close() {
	s.reqShare <- shareRequestShutdown
	<-s.resShare
}

func (s *shareFactory) refresh() (*smb2.Share, error) {
	s.reqShare <- shareRequestRefresh
	result := <-s.resShare
	return result.session, result.err
}

func (s *shareFactory) keep() {
	s.reqShare <- shareRequestKeep
}

func (s *shareFactory) openSession() error {
	conn, err := net.Dial("tcp", s.addr)
	if err != nil {
		return err
	}

	d := &smb2.Dialer{
		Initiator: &smb2.NTLMInitiator{
			User:     s.username,
			Password: s.password,
		},
	}

	sess, err := d.Dial(conn)
	if err != nil {
		return err
	}

	fs, err := sess.Mount(s.sharename)
	if err != nil {
		return err
	}

	s.conn = conn
	s.session = sess
	s.share = fs

	return nil
}

func (s *shareFactory) closeSession() {
	s.share.Umount()
	s.session.Logoff()
	s.conn.Close()
	s.share = nil
	s.session = nil
	s.conn = nil
}

func retry[T any](factory *shareFactory, f func(*smb2.Share) (T, error)) (T, error) {
	var ret T
	share, err := factory.getShare()
	if errors.Is(err, &smb2.TransportError{}) {
		share, err = factory.refresh()
		if err != nil {
			return ret, err
		}
	}

	ret, err = f(share)
	if errors.Is(err, &smb2.TransportError{}) {
		share, err = factory.refresh()
		if err != nil {
			return ret, err
		}
		return f(share)
	}
	return ret, err
}

func retryVoid(factory *shareFactory, f func(*smb2.Share) error) error {
	share, err := factory.getShare()
	if errors.Is(err, &smb2.TransportError{}) {
		share, err = factory.refresh()
		if err != nil {
			return err
		}
	}

	err = f(share)
	if errors.Is(err, &smb2.TransportError{}) {
		share, err = factory.refresh()
		if err != nil {
			return err
		}
		return f(share)
	}
	return err
}
