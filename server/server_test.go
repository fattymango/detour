package main

import (
	"fmt"
	"io"
	"net"
	"net/netip"
	"path/filepath"
	"testing"
	"time"

	"golang.org/x/crypto/bcrypt"
)

func TestIPsAreReused(t *testing.T) {
	s := &server{nextIP: firstClientIP, subnet: [3]byte{10, 10, 0}}
	for range 1000 {
		ip, ok := s.allocateIP()
		if !ok {
			t.Fatal("ran out of IPs despite releasing them")
		}
		s.releaseIP(ip)
	}
	seen := map[[4]byte]bool{}
	for range 252 {
		ip, ok := s.allocateIP()
		if !ok || seen[ip] || ip[3] < 2 || ip[3] > 253 {
			t.Fatalf("bad allocation %v ok=%v", ip, ok)
		}
		seen[ip] = true
	}
	if _, ok := s.allocateIP(); ok {
		t.Fatal("allocated an IP from a full pool")
	}
	s.releaseIP([4]byte{10, 10, 0, 77})
	if ip, ok := s.allocateIP(); !ok || ip[3] != 77 {
		t.Fatalf("got %v, want the one free IP", ip)
	}
}

func TestLoginLimiter(t *testing.T) {
	now := time.Now()
	var l loginLimiter
	for i := range maxFailedLogins {
		if !l.begin("a", now) {
			t.Fatalf("attempt %d refused", i)
		}
		l.end("a", true, now)
	}
	if l.begin("a", now) {
		t.Fatal("not blocked after too many failures")
	}
	if !l.begin("b", now) {
		t.Fatal("other source blocked")
	}
	l.end("b", false, now)
	later := now.Add(failedLoginWindow)
	if !l.begin("a", later) {
		t.Fatal("still blocked after the window")
	}
	l.end("a", false, later)
	if len(l.sources) != 0 || l.pending != 0 {
		t.Fatalf("leaked state: %v pending=%d", l.sources, l.pending)
	}

	for range maxPendingLoginsPerSource {
		l.begin("a", later)
	}
	if l.begin("a", later) {
		t.Fatal("per-source pending limit not enforced")
	}
	for i := l.pending; i < maxPendingLogins; i++ {
		l.begin(fmt.Sprintf("other%d", i), later)
	}
	if l.begin("new", later) {
		t.Fatal("global pending limit not enforced")
	}
}

func TestLoginSource(t *testing.T) {
	for in, want := range map[string]string{
		"1.2.3.4:5":          "1.2.3.4",
		"[::ffff:1.2.3.4]:5": "1.2.3.4",
		"[2001:db8::1]:5":    "2001:db8::/64",
		"[2001:db8::ff]:9":   "2001:db8::/64",
	} {
		if got := loginSource(net.TCPAddrFromAddrPort(netip.MustParseAddrPort(in))); got != want {
			t.Errorf("%s: got %s, want %s", in, got, want)
		}
	}
}

func TestHandleConn(t *testing.T) {
	old := loginTimeout
	loginTimeout = time.Second
	defer func() { loginTimeout = old }()

	db, err := openUserDB(filepath.Join(t.TempDir(), "users.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	hash, _ := bcrypt.GenerateFromPassword([]byte("pw"), bcrypt.MinCost)
	if _, err := db.Exec("INSERT INTO users (username, password_hash) VALUES ('u', ?)", string(hash)); err != nil {
		t.Fatal(err)
	}
	s := &server{clients: map[[4]byte]*client{}, nextIP: firstClientIP, userDB: db}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	done := make(chan struct{}, 100)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { s.handleConn(c); done <- struct{}{} }()
		}
	}()
	dial := func() net.Conn {
		c, err := net.Dial("tcp", ln.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		c.SetDeadline(time.Now().Add(5 * time.Second))
		return c
	}
	login := func(pw string) (net.Conn, []byte) {
		c := dial()
		c.Write(append([]byte{1, 'u', byte(len(pw))}, pw...))
		b := make([]byte, 1)
		n, _ := io.ReadFull(c, b)
		return c, b[:n]
	}

	silent := dial()
	if _, err := silent.Read(make([]byte, 1)); err != io.EOF {
		t.Fatalf("silent connection: got %v, want it closed", err)
	}
	<-done

	c, resp := login("pw")
	if len(resp) != 1 || resp[0] != 0 {
		t.Fatalf("good password: got %v", resp)
	}
	ip := make([]byte, 4)
	if _, err := io.ReadFull(c, ip); err != nil {
		t.Fatal(err)
	}
	time.Sleep(2 * loginTimeout)
	select {
	case <-done:
		t.Fatal("login timeout cut off an authenticated client")
	default:
	}
	s.mu.Lock()
	active := s.clients[[4]byte(ip)]
	s.mu.Unlock()
	if err := active.writeFramedLocked([]byte("x")); err != nil {
		t.Fatalf("login deadline still applies to writes: %v", err)
	}
	c.Close()
	<-done
	if s.usedIPs[ip[3]] || len(s.clients) != 0 {
		t.Fatal("IP not released on disconnect")
	}

	for i := range maxFailedLogins {
		c, resp := login("bad")
		if len(resp) != 1 || resp[0] != 1 {
			t.Fatalf("bad password %d: got %v", i, resp)
		}
		c.Close()
		<-done
	}
	if _, resp := login("pw"); len(resp) != 0 {
		t.Fatalf("blocked source still got an answer: %v", resp)
	}
}
