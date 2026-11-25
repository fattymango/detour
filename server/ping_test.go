package main

import (
	"io"
	"testing"
	"time"
)

func TestPing(t *testing.T) {
	e := newEnv(t, "u")
	c, ip := e.vpn("u")
	for range 2 {
		writeFramed(c, []byte{framePing})
		var frame [3]byte
		if _, err := io.ReadFull(c, frame[:]); err != nil || frame != [3]byte{0, 1, framePong} {
			t.Fatalf("got %v, %v", frame, err)
		}
	}
	e.s.mu.Lock()
	pings := e.s.clients[ip].pings.Load()
	e.s.mu.Unlock()
	if !pings {
		t.Error("client still treated as needing heartbeats")
	}
	time.Sleep(50 * time.Millisecond)
	if n := len(e.tun.out); n != 0 {
		t.Errorf("%d control frames reached the network", n)
	}
	if u := e.info("u"); u.UsedBytes != 0 {
		t.Errorf("pings were counted: %d bytes", u.UsedBytes)
	}
}
