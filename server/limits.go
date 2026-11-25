package main

import (
	"errors"
	"log"
	"sync"
	"sync/atomic"
	"time"
)

const (
	minSpeedKbps = 64
	maxSpeedKbps = 10_000_000
	speedBurst   = 200 * time.Millisecond
	// Packets that would have to wait longer than this are dropped, which is
	// how TCP learns to slow down. Delaying them instead fills the sender's
	// buffers, so apps see uploads far above the limit.
	maxDelay = 500 * time.Millisecond
)

func checkLimits(speedKbps, quotaBytes int64) error {
	if speedKbps != 0 && (speedKbps < minSpeedKbps || speedKbps > maxSpeedKbps) {
		return errors.New("speed must be 0 (unlimited) or between 64 kbps and 10 Gbps")
	}
	if quotaBytes < 0 {
		return errors.New("data limit can't be negative")
	}
	return nil
}

// throttle schedules packets so they average the given speed.
type throttle struct {
	mu   sync.Mutex
	next time.Time
}

// reserve returns when a packet of n bytes may be sent. It refuses
// packets that would wait longer than maxDelay.
func (t *throttle) reserve(n int, speedKbps int64, now time.Time) (time.Time, bool) {
	if speedKbps <= 0 {
		return now, true
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if earliest := now.Add(-speedBurst); t.next.Before(earliest) {
		t.next = earliest
	}
	at := t.next
	if at.Sub(now) > maxDelay {
		return at, false
	}
	t.next = at.Add(time.Duration(float64(n*8) / float64(speedKbps*1000) * float64(time.Second)))
	return at, true
}

// meter holds one user's limits and usage, shared by all their connections.
type meter struct {
	up, down  throttle
	speedKbps atomic.Int64
	quota     atomic.Int64
	saved     atomic.Int64 // usage already in the database
	pending   atomic.Int64 // usage not yet in the database
}

func (m *meter) load(u user) {
	m.speedKbps.Store(u.speedKbps)
	m.quota.Store(u.quotaBytes)
	m.saved.Store(u.usedBytes)
}

func (m *meter) used() int64 { return m.saved.Load() + m.pending.Load() }

func (m *meter) overQuota() bool {
	q := m.quota.Load()
	return q > 0 && m.used() >= q
}

func (s *server) meterFor(u user) *meter {
	s.mu.Lock()
	defer s.mu.Unlock()
	m := s.meters[u.name]
	if m == nil {
		m = &meter{}
		m.load(u)
		if s.meters == nil {
			s.meters = map[string]*meter{}
		}
		s.meters[u.name] = m
	}
	return m
}

// flushUsage saves unsaved usage. Callers hold syncMu.
// shortcut: a crash or restart loses up to syncInterval of usage, flush on SIGTERM if that matters.
func (s *server) flushUsage() {
	s.mu.Lock()
	meters := make(map[string]*meter, len(s.meters))
	for name, m := range s.meters {
		meters[name] = m
	}
	s.mu.Unlock()
	for name, m := range meters {
		n := m.pending.Load()
		if n == 0 {
			continue
		}
		if _, err := s.userDB.Exec("UPDATE users SET used_bytes = used_bytes + ? WHERE username = ?", n, name); err != nil {
			log.Printf("saving usage of %q: %v", name, err)
			continue
		}
		// In this order, usage is briefly too low rather than too high.
		m.pending.Add(-n)
		m.saved.Add(n)
	}
}
