package main

import (
	"database/sql"
	"encoding/json"
	"io"
	"net"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/songgao/water"
)

func TestThrottle(t *testing.T) {
	now := time.Now()
	var th throttle
	passed := 0
	for range 10_000 {
		if _, ok := th.reserve(1250, 10_000, now); ok { // 1 ms per packet
			passed++
		}
	}
	if want := int((speedBurst + maxDelay) / time.Millisecond); passed < want || passed > want+1 {
		t.Errorf("%d packets passed at once, want %d", passed, want)
	}
	if at, ok := th.reserve(1250, 0, now); !ok || !at.Equal(now) {
		t.Error("unlimited speed was throttled")
	}
	later := now.Add(time.Hour)
	if at, ok := th.reserve(1250, 10_000, later); !ok || at.After(later) {
		t.Error("idle time didn't clear the backlog")
	}
}

func TestCheckLimits(t *testing.T) {
	for _, ok := range [][2]int64{{0, 0}, {64, 1}, {10_000_000, 1 << 50}} {
		if err := checkLimits(ok[0], ok[1]); err != nil {
			t.Errorf("%v: %v", ok, err)
		}
	}
	for _, bad := range [][2]int64{{-1, 0}, {1, 0}, {10_000_001, 0}, {0, -1}} {
		if checkLimits(bad[0], bad[1]) == nil {
			t.Errorf("accepted %v", bad)
		}
	}
}

type fakeTun struct {
	in  chan []byte
	out chan []byte
}

func (f *fakeTun) Read(b []byte) (int, error) {
	p, ok := <-f.in
	if !ok {
		return 0, io.EOF
	}
	return copy(b, p), nil
}

func (f *fakeTun) Write(b []byte) (int, error) {
	f.out <- append([]byte(nil), b...)
	return len(b), nil
}

func (f *fakeTun) Close() error { return nil }

func claimAll(t *testing.T, db *sql.DB) {
	t.Helper()
	if _, err := db.Exec("UPDATE users SET is_invite = 0"); err != nil {
		t.Fatal(err)
	}
}

type env struct {
	t   *testing.T
	s   *server
	tun *fakeTun
	ln  net.Listener
}

func newEnv(t *testing.T, users ...string) *env {
	db, err := openUserDB(filepath.Join(t.TempDir(), "users.db"))
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range append(users, "boss") {
		if err := addUser(db, name, "pw"); err != nil {
			t.Fatal(err)
		}
	}
	claimAll(t, db)
	if err := setAdmin(db, "boss", true); err != nil {
		t.Fatal(err)
	}
	tun := &fakeTun{make(chan []byte), make(chan []byte, 100_000)}
	s := &server{clients: map[[4]byte]*client{}, nextIP: firstClientIP, userDB: db, subnet: [3]byte{10, 10, 0}, tun: &water.Interface{ReadWriteCloser: tun}}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close(); close(tun.in); db.Close() })
	go s.tunReadLoop()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go s.handleConn(c)
		}
	}()
	return &env{t, s, tun, ln}
}

func (e *env) open(marker, name string) (net.Conn, byte) {
	e.t.Helper()
	c, err := net.Dial("tcp", e.ln.Addr().String())
	if err != nil {
		e.t.Fatal(err)
	}
	e.t.Cleanup(func() { c.Close() })
	c.SetDeadline(time.Now().Add(20 * time.Second))
	io.WriteString(c, marker+string(rune(len(name)))+name+"\x02pw")
	b := make([]byte, 1)
	if _, err := io.ReadFull(c, b); err != nil {
		e.t.Fatal(err)
	}
	return c, b[0]
}

func (e *env) vpn(name string) (net.Conn, [4]byte) {
	e.t.Helper()
	c, status := e.open("", name)
	if status != 0 {
		e.t.Fatalf("%s: status %d", name, status)
	}
	var ip [4]byte
	if _, err := io.ReadFull(c, ip[:]); err != nil {
		e.t.Fatal(err)
	}
	for end := time.Now().Add(2 * time.Second); time.Now().Before(end); time.Sleep(time.Millisecond) {
		e.s.mu.Lock()
		_, ok := e.s.clients[ip]
		e.s.mu.Unlock()
		if ok {
			break
		}
	}
	return c, ip
}

func (e *env) admin(req adminRequest) adminResponse {
	e.t.Helper()
	c, _ := e.open("\x00", "boss")
	defer c.Close()
	body, _ := json.Marshal(req)
	writeFramed(c, body)
	var resp adminResponse
	if err := json.NewDecoder(c).Decode(&resp); err != nil {
		e.t.Fatal(err)
	}
	return resp
}

func (e *env) set(name string, kbps, quota int64) {
	e.t.Helper()
	if r := e.admin(adminRequest{Op: "setlimits", Username: name, SpeedKbps: kbps, QuotaBytes: quota}); r.Error != "" {
		e.t.Fatal(r.Error)
	}
}

func (e *env) info(name string) adminUser {
	e.t.Helper()
	for _, u := range e.admin(adminRequest{Op: "list"}).Users {
		if u.Username == name {
			return u
		}
	}
	e.t.Fatalf("no user %s", name)
	return adminUser{}
}

func packetTo(ip [4]byte) []byte {
	p := make([]byte, 1000)
	copy(p[16:], ip[:])
	return p
}

// readFor counts packet bytes the client receives until d passes or it's cut off.
func readFor(c net.Conn, d time.Duration) (n int, cut bool) {
	c.SetReadDeadline(time.Now().Add(d))
	for {
		var h [2]byte
		if _, err := io.ReadFull(c, h[:]); err != nil {
			ne, ok := err.(net.Error)
			return n, !(ok && ne.Timeout())
		}
		size := int(h[0])<<8 | int(h[1])
		if _, err := io.CopyN(io.Discard, c, int64(size)); err != nil {
			return n, true
		}
		n += size
	}
}

func TestDownloadSpeedIsPerUser(t *testing.T) {
	e := newEnv(t, "slow", "fast")
	e.set("slow", 2000, 0) // 250 kB/s
	a, ipA := e.vpn("slow")
	b, ipB := e.vpn("slow")
	f, ipF := e.vpn("fast")
	stop := make(chan struct{})
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		for {
			for _, ip := range [][4]byte{ipA, ipB, ipF} {
				select {
				case <-stop:
					return
				case e.tun.in <- packetTo(ip):
				}
			}
			time.Sleep(100 * time.Microsecond)
		}
	}()
	got := make(chan [2]int, 3)
	for i, c := range []net.Conn{a, b, f} {
		go func() { n, _ := readFor(c, 2*time.Second); got <- [2]int{i, n} }()
	}
	var n [3]int
	for range 3 {
		r := <-got
		n[r[0]] = r[1]
	}
	close(stop)
	<-stopped
	slow := n[0] + n[1]
	if slow < 400_000 || slow > 620_000 {
		t.Errorf("slow user's two devices got %d bytes in 2s, want about 500-550k", slow)
	}
	if n[2] < 3*slow {
		t.Errorf("unlimited user got %d, held back by the slow one's %d", n[2], slow)
	}
}

func TestUploadSpeed(t *testing.T) {
	e := newEnv(t, "slow")
	e.set("slow", 2000, 0)
	c, ip := e.vpn("slow")
	var offered atomic.Int64
	var gentle atomic.Bool
	go func() {
		for writeFramed(c, packetFrom(ip, 1000)) == nil {
			offered.Add(1000)
			if gentle.Load() {
				time.Sleep(200 * time.Microsecond)
			}
		}
	}()
	time.Sleep(2 * time.Second)
	// The excess must be dropped, not left to fill the sender's buffers.
	gentle.Store(true)
	if n := offered.Load(); n < 20_000_000 {
		t.Errorf("server held the sender back to %d bytes", n)
	}
	if n := len(e.tun.out) * 1000; n < 400_000 || n > 620_000 {
		t.Errorf("uploaded %d bytes in 2s", n)
	}
	e.set("slow", 0, 0)
	before := len(e.tun.out)
	time.Sleep(500 * time.Millisecond)
	if n := (len(e.tun.out) - before) * 1000; n < 400_000 {
		t.Errorf("lifting the limit didn't take effect live: %d bytes", n)
	}
	c.Close()
}

func TestStalledClientDoesNotBlockOthers(t *testing.T) {
	e := newEnv(t, "stalled", "ok")
	_, ipS := e.vpn("stalled") // never reads
	c, ip := e.vpn("ok")
	go func() {
		for range 20_000 {
			e.tun.in <- packetTo(ipS)
		}
		for range 10 {
			e.tun.in <- packetTo(ip)
		}
	}()
	if n, _ := readFor(c, 3*time.Second); n != 10_000 {
		t.Errorf("got %d bytes, want 10000", n)
	}
}

func TestQuota(t *testing.T) {
	e := newEnv(t, "u", "other")
	e.set("u", 0, 50_000)
	c, ip := e.vpn("u")
	for range 20 {
		writeFramed(c, packetFrom(ip, 1000))
		e.tun.in <- packetTo(ip)
	}
	if n, cut := readFor(c, 500*time.Millisecond); n != 20_000 || cut {
		t.Fatalf("before the limit: %d bytes, cut=%v", n, cut)
	}
	if u := e.info("u"); u.UsedBytes != 40_000 || u.QuotaBytes != 50_000 {
		t.Fatalf("usage: %+v", u)
	}
	go func() {
		for range 100 {
			e.tun.in <- packetTo(ip)
		}
	}()
	if n, cut := readFor(c, 3*time.Second); n != 10_000 || !cut {
		t.Errorf("download limit: got %d more bytes, cut=%v", n, cut)
	}
	if _, status := e.open("", "u"); status != 3 {
		t.Errorf("over quota login: status %d", status)
	}
	e.s.syncUsers()
	e.s.mu.Lock()
	e.s.meters = nil // as after a restart
	e.s.mu.Unlock()
	if _, status := e.open("", "u"); status != 3 {
		t.Errorf("over quota login after restart: status %d", status)
	}

	if r := e.admin(adminRequest{Op: "resetusage", Username: "u"}); r.Error != "" {
		t.Fatal(r.Error)
	}
	if u := e.info("u"); u.UsedBytes != 0 {
		t.Errorf("after reset: %+v", u)
	}
	c, ip = e.vpn("u")
	sent := len(e.tun.out)
	for range 100 {
		writeFramed(c, packetFrom(ip, 1000))
	}
	if _, cut := readFor(c, 3*time.Second); !cut || len(e.tun.out)-sent != 50 {
		t.Errorf("upload limit: %d packets passed, cut=%v", len(e.tun.out)-sent, cut)
	}

	e.admin(adminRequest{Op: "resetusage", Username: "u"})
	c, ip = e.vpn("u")
	for range 20 {
		writeFramed(c, packetFrom(ip, 1000))
	}
	time.Sleep(200 * time.Millisecond)
	e.set("u", 0, 10_000)
	if _, cut := readFor(c, 3*time.Second); !cut {
		t.Error("lowering the limit below current usage didn't disconnect")
	}
	e.admin(adminRequest{Op: "remove", Username: "u"})
	if err := addUser(e.s.userDB, "u", "pw"); err != nil {
		t.Fatal(err)
	}
	claimAll(t, e.s.userDB)
	if u := e.info("u"); u.UsedBytes != 0 || u.QuotaBytes != 0 {
		t.Errorf("recreated user inherited limits: %+v", u)
	}
	e.vpn("u")
	if r := e.admin(adminRequest{Op: "setlimits", Username: "u", SpeedKbps: 1}); r.Error == "" {
		t.Error("accepted an invalid speed")
	}
	if u := e.info("other"); u.UsedBytes != 0 {
		t.Errorf("other user was charged: %+v", u)
	}
}
