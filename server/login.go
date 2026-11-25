package main

import (
	"net"
	"net/netip"
	"sync"
	"time"

	"golang.org/x/crypto/bcrypt"
)

const (
	maxPendingLogins          = 128
	maxPendingLoginsPerSource = 8
	maxFailedLogins           = 10
	failedLoginWindow         = 5 * time.Minute
)

var dummyHash = func() string {
	hash, err := bcrypt.GenerateFromPassword([]byte("unused"), bcrypt.DefaultCost)
	if err != nil {
		panic(err)
	}
	return string(hash)
}()

type loginRecord struct {
	pending     int
	failed      int
	windowStart time.Time
}

// loginLimiter caps unauthenticated connections and password guesses.
type loginLimiter struct {
	mu      sync.Mutex
	pending int
	sources map[string]*loginRecord
	pruned  time.Time
}

// begin reports whether source may try to log in; if so, end must be called.
func (l *loginLimiter) begin(source string, now time.Time) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.prune(now)
	if l.pending >= maxPendingLogins {
		return false
	}
	if l.sources == nil {
		l.sources = map[string]*loginRecord{}
	}
	rec := l.sources[source]
	if rec == nil {
		rec = &loginRecord{}
		l.sources[source] = rec
	}
	if now.Sub(rec.windowStart) >= failedLoginWindow {
		rec.failed = 0
	}
	// Pending logins count too, so parallel guesses can't exceed the limit.
	if rec.pending >= maxPendingLoginsPerSource || rec.failed+rec.pending >= maxFailedLogins {
		return false
	}
	rec.pending++
	l.pending++
	return true
}

func (l *loginLimiter) end(source string, rejected bool, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	rec := l.sources[source]
	rec.pending--
	l.pending--
	if rejected {
		if rec.failed == 0 {
			rec.windowStart = now
		}
		rec.failed++
	}
	if rec.pending == 0 && rec.failed == 0 {
		delete(l.sources, source)
	}
}

func (l *loginLimiter) prune(now time.Time) {
	if now.Sub(l.pruned) < failedLoginWindow {
		return
	}
	l.pruned = now
	for source, rec := range l.sources {
		if rec.pending == 0 && now.Sub(rec.windowStart) >= failedLoginWindow {
			delete(l.sources, source)
		}
	}
}

// loginSource groups IPv6 by /64, since one host usually owns a whole /64.
func loginSource(addr net.Addr) string {
	ap, err := netip.ParseAddrPort(addr.String())
	if err != nil {
		return addr.String()
	}
	ip := ap.Addr().Unmap()
	if ip.Is4() {
		return ip.String()
	}
	prefix, _ := ip.WithZone("").Prefix(64)
	return prefix.String()
}
