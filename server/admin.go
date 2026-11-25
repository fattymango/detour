package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"log"
	"net"
	"regexp"
	"time"
)

const (
	// adminMarker takes the place of the username length, which is never 0.
	adminMarker     = 0
	maxAdminRequest = 4096
	syncInterval    = 5 * time.Second
)

var usernamePattern = regexp.MustCompile(`^[A-Za-z0-9._-]{1,32}$`)

var claimPattern = regexp.MustCompile(`^[A-Za-z0-9]{32,64}$`)

func checkUsername(name string) error {
	if !usernamePattern.MatchString(name) {
		return errors.New("username must be 1-32 letters, digits, dots, dashes or underscores")
	}
	return nil
}

type adminRequest struct {
	Op       string `json:"op"`
	Username string `json:"username"`
	Password string `json:"password"` // for claim

	// For setlimits; 0 means unlimited.
	SpeedKbps  int64 `json:"speedKbps"`
	QuotaBytes int64 `json:"quotaBytes"`
}

type adminUser struct {
	Username  string `json:"username"`
	Admin     bool   `json:"admin"`
	Invite    bool   `json:"invite"`
	Connected int    `json:"connected"`

	SpeedKbps  int64 `json:"speedKbps"`
	QuotaBytes int64 `json:"quotaBytes"`
	UsedBytes  int64 `json:"usedBytes"`
}

type adminResponse struct {
	Error    string      `json:"error,omitempty"`
	Users    []adminUser `json:"users,omitempty"`
	Password string      `json:"password,omitempty"`
	Claimed  bool        `json:"claimed,omitempty"`
}

// handleAdmin serves one request on an already authenticated connection:
// status byte 0, then one framed JSON request, then one JSON line back.
func (s *server) handleAdmin(conn net.Conn, r *bufio.Reader, u user) {
	conn.SetDeadline(time.Now().Add(loginTimeout))
	if _, err := conn.Write([]byte{0}); err != nil {
		return
	}
	body, err := readFramedMax(r, maxAdminRequest)
	if err != nil {
		return
	}
	var req adminRequest
	var resp adminResponse
	if err := json.Unmarshal(body, &req); err != nil {
		resp.Error = "bad request"
	} else if resp, err = s.runAdmin(u, req); err != nil {
		resp = adminResponse{Error: err.Error()}
	}
	json.NewEncoder(conn).Encode(resp)
}

func (s *server) runAdmin(u user, req adminRequest) (resp adminResponse, err error) {
	if req.Op == "claim" {
		return s.claim(u, req.Password)
	}
	if u.invite {
		return resp, errors.New("this invite hasn't been claimed")
	}
	if !u.admin {
		return resp, errors.New("you are not an admin of this server")
	}
	s.syncMu.Lock()
	defer s.syncMu.Unlock()
	s.flushUsage()
	switch req.Op {
	case "list":
		users, err := listUsers(s.userDB)
		if err != nil {
			return resp, err
		}
		connected := map[string]int{}
		s.mu.Lock()
		for _, c := range s.clients {
			connected[c.user.name]++
		}
		s.mu.Unlock()
		for _, u := range users {
			resp.Users = append(resp.Users, adminUser{u.name, u.admin, u.invite, connected[u.name], u.speedKbps, u.quotaBytes, u.usedBytes})
		}
		return resp, nil
	case "add":
		if err := checkUsername(req.Username); err != nil {
			return resp, err
		}
		resp.Password = generatePassword()
		err = addUser(s.userDB, req.Username, resp.Password)
	case "reset":
		resp.Password = generatePassword()
		err = setPassword(s.userDB, req.Username, resp.Password)
	case "remove":
		if req.Username == u.name {
			return resp, errors.New("you can't remove yourself")
		}
		err = deleteUser(s.userDB, req.Username)
	case "setlimits":
		if err := checkLimits(req.SpeedKbps, req.QuotaBytes); err != nil {
			return resp, err
		}
		err = setLimits(s.userDB, req.Username, req.SpeedKbps, req.QuotaBytes)
	case "resetusage":
		err = resetUsage(s.userDB, req.Username)
	default:
		err = errors.New("unknown operation")
	}
	if err != nil {
		return resp, err
	}
	log.Printf("admin %q: %s %q", u.name, req.Op, req.Username)
	s.applyUsers()
	return resp, nil
}

// claim turns an invite into this device's own login. Claiming again is
// harmless, so a client that missed the answer can check with its new password.
func (s *server) claim(u user, password string) (resp adminResponse, err error) {
	if !u.invite {
		return resp, nil
	}
	if !claimPattern.MatchString(password) {
		return resp, errors.New("bad new password")
	}
	if err := claimInvite(s.userDB, u, password); err != nil {
		return resp, errors.New("this invite link was already used or cancelled")
	}
	log.Printf("user %q claimed their invite", u.name)
	resp.Claimed = true
	return resp, nil
}

// applyUsers brings running connections in line with the database: it updates
// limits, and disconnects removed users, changed passwords and used-up quotas.
// Callers hold syncMu.
func (s *server) applyUsers() {
	users, err := listUsers(s.userDB)
	if err != nil {
		log.Printf("reading users: %v", err)
		return
	}
	byName := map[string]user{}
	for _, u := range users {
		byName[u.name] = u
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for name, m := range s.meters {
		if u, ok := byName[name]; ok {
			m.load(u)
		} else {
			delete(s.meters, name)
			delete(s.lastIP, name)
		}
	}
	for _, c := range s.clients {
		if byName[c.user.name].hash != c.user.hash {
			log.Printf("disconnecting %q: access revoked", c.user.name)
			go c.conn.Close() // TLS close can wait on a stalled client
		} else if c.meter.overQuota() {
			log.Printf("disconnecting %q: data limit reached", c.user.name)
			go c.conn.Close()
		}
	}
}

// syncUsers also catches changes made by the CLI, and logins that raced a removal.
func (s *server) syncUsers() {
	s.syncMu.Lock()
	defer s.syncMu.Unlock()
	s.flushUsage()
	s.applyUsers()
}

func (s *server) syncLoop() {
	for range time.Tick(syncInterval) {
		s.syncUsers()
	}
}
