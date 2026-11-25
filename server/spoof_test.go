package main

import (
	"testing"
	"time"
)

func packetFrom(ip [4]byte, size int) []byte {
	p := make([]byte, size)
	p[0] = 0x45
	copy(p[12:], ip[:])
	return p
}

func TestSpoofedPacketsAreDropped(t *testing.T) {
	e := newEnv(t, "a", "b")
	a, ipA := e.vpn("a")
	_, ipB := e.vpn("b")
	v6 := packetFrom(ipA, 100)
	v6[0] = 0x60
	for _, p := range [][]byte{packetFrom(ipB, 100), packetFrom([4]byte{8, 8, 8, 8}, 100), make([]byte, 100), v6, packetFrom(ipA, 20)[:19], {0x45}} {
		writeFramed(a, p)
	}
	writeFramed(a, packetFrom(ipA, 100))
	time.Sleep(300 * time.Millisecond)
	if n := len(e.tun.out); n != 1 {
		t.Fatalf("%d packets reached the network, want only the genuine one", n)
	}
	if p := <-e.tun.out; [4]byte(p[12:16]) != ipA {
		t.Errorf("wrong packet passed: from %v", p[12:16])
	}
	if u := e.info("a"); u.UsedBytes != 100 {
		t.Errorf("dropped packets were counted: %d bytes", u.UsedBytes)
	}
}
