package main

import (
	"bufio"
	"crypto/tls"
	"database/sql"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/songgao/water"
	"golang.org/x/crypto/bcrypt"
)

var (
	listenAddr = flag.String("listen", ":443", "TLS listen address")
	certFile   = flag.String("cert", "/etc/detour/server.crt", "TLS certificate")
	keyFile    = flag.String("key", "/etc/detour/server.key", "TLS private key")
	dbPath     = flag.String("db", "/var/lib/detour/users.db", "detour-server's own user database (see adduser/deluser/setadmin/listusers)")
	tunName    = flag.String("tun", "tun0", "TUN device name")
	subnet     = flag.String("subnet", "10.10.0", "subnet /24 prefix, e.g. 10.10.0 -> 10.10.0.1 is server, .2+ handed to clients")
)

// Heartbeats (zero-length frames) keep the TCP connection looking "active" to
// any middlebox tracking connection state (routers, DPI, carrier-grade NAT),
// which otherwise silently drop it after a minute or so of no real traffic
// (e.g. between video segments) - the client then hangs forever waiting for
// data that will never come. readTimeout must be well above heartbeatInterval
// so a couple of missed/delayed heartbeats don't cause a false disconnect.
const (
	heartbeatInterval = 15 * time.Second
	readTimeout       = 40 * time.Second
)

// clientQueue bounds the packets waiting for one client.
const clientQueue = 512

// loginTimeout covers the TLS handshake plus the auth frame.
var loginTimeout = 10 * time.Second

type client struct {
	conn    net.Conn
	writeMu sync.Mutex
	ip      [4]byte
	user    user
	meter   *meter
	in, out chan packet
}

type packet struct {
	data []byte
	at   time.Time
}

// schedule queues a packet for a direction's writer without ever blocking, so one
// slow or throttled client can't hold up the others.
func (c *client) schedule(t *throttle, queue chan<- packet, data []byte) {
	now := time.Now()
	at, ok := t.reserve(len(data), c.meter.speedKbps.Load(), now)
	if !ok {
		return
	}
	select {
	case queue <- packet{data, at}:
	default:
	}
}

// drain sends one direction's queued packets at their scheduled times. It
// closes the connection if sending fails or the user runs out of data.
func (c *client) drain(queue <-chan packet, send func([]byte) error, done <-chan struct{}) {
	for {
		select {
		case <-done:
			return
		case p := <-queue:
			time.Sleep(time.Until(p.at))
			if c.meter.overQuota() {
				log.Printf("disconnecting %q: data limit reached", c.user.name)
				c.conn.Close()
				return
			}
			if err := send(p.data); err != nil {
				c.conn.Close()
				return
			}
			c.meter.pending.Add(int64(len(p.data)))
		}
	}
}

func (c *client) writeFramedLocked(pkt []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	return writeFramed(c.conn, pkt)
}

type server struct {
	mu      sync.Mutex
	clients map[[4]byte]*client
	nextIP  byte
	usedIPs [256]bool
	logins  loginLimiter
	meters  map[string]*meter
	syncMu  sync.Mutex // serializes usage flushes and user changes
	tun     *water.Interface
	userDB  *sql.DB
	subnet  [3]byte
}

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "adduser", "deluser", "listusers", "setadmin":
			runUserCommand(os.Args[1], os.Args[2:])
			return
		case "serve":
			os.Args = append(os.Args[:1], os.Args[2:]...)
		}
	}
	flag.Parse()
	runServe()
}

func runServe() {
	userDB, err := openUserDB(*dbPath)
	if err != nil {
		log.Fatalf("opening user database: %v", err)
	}
	if err := userDB.Ping(); err != nil {
		log.Fatalf("connecting to user database: %v", err)
	}
	defer userDB.Close()

	cert, err := tls.LoadX509KeyPair(*certFile, *keyFile)
	if err != nil {
		log.Fatalf("loading cert: %v", err)
	}

	iface, err := water.New(water.Config{DeviceType: water.TUN, PlatformSpecificParams: water.PlatformSpecificParams{Name: *tunName}})
	if err != nil {
		log.Fatalf("creating tun: %v", err)
	}
	log.Printf("created tun device: %s", iface.Name())

	serverAddr := fmt.Sprintf("%s.1/24", *subnet)
	if out, err := exec.Command("ip", "addr", "add", serverAddr, "dev", iface.Name()).CombinedOutput(); err != nil {
		log.Fatalf("ip addr add: %v: %s", err, out)
	}
	if out, err := exec.Command("ip", "link", "set", "dev", iface.Name(), "up").CombinedOutput(); err != nil {
		log.Fatalf("ip link set up: %v: %s", err, out)
	}
	log.Printf("configured %s with address %s", iface.Name(), serverAddr)

	subnetParts := strings.Split(*subnet, ".")
	if len(subnetParts) != 3 {
		log.Fatalf("subnet must be like 10.10.0")
	}
	var subnetBytes [3]byte
	for i, p := range subnetParts {
		n, _ := strconv.Atoi(p)
		subnetBytes[i] = byte(n)
	}

	s := &server{
		clients: map[[4]byte]*client{},
		nextIP:  firstClientIP,
		tun:     iface,
		userDB:  userDB,
		subnet:  subnetBytes,
	}

	go s.tunReadLoop()
	go s.syncLoop()

	tlsCfg := &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}
	ln, err := tls.Listen("tcp", *listenAddr, tlsCfg)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	log.Printf("listening on %s", *listenAddr)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept error: %v", err)
			continue
		}
		go s.handleConn(conn)
	}
}

// tunReadLoop reads packets from the TUN device and dispatches them to the
// client whose assigned virtual IP matches the packet's destination address.
func (s *server) tunReadLoop() {
	buf := make([]byte, 65536)
	for {
		n, err := s.tun.Read(buf)
		if err != nil {
			log.Printf("tun read error: %v", err)
			return
		}
		if n < 20 {
			continue // not a valid IPv4 packet
		}
		var dst [4]byte
		copy(dst[:], buf[16:20])

		s.mu.Lock()
		c, ok := s.clients[dst]
		s.mu.Unlock()
		if !ok {
			continue
		}
		c.schedule(&c.meter.down, c.out, append([]byte(nil), buf[:n]...))
	}
}

func (s *server) handleConn(conn net.Conn) {
	defer conn.Close()
	source := loginSource(conn.RemoteAddr())
	if !s.logins.begin(source, time.Now()) {
		return
	}
	r := bufio.NewReader(conn)
	conn.SetDeadline(time.Now().Add(loginTimeout))
	u, admin, ok := s.authenticate(conn, r, source)
	if !ok {
		return
	}
	if admin {
		s.handleAdmin(conn, r, u)
		return
	}
	m := s.meterFor(u)
	if m.overQuota() {
		log.Printf("user %q is over their data limit", u.name)
		conn.Write([]byte{3})
		return
	}
	conn.SetDeadline(time.Time{})

	ip, ok := s.allocateIP()
	if !ok {
		log.Printf("no free IPs for user %q", u.name)
		conn.Write([]byte{2})
		return
	}
	defer s.releaseIP(ip)

	log.Printf("user %q connected from %s, assigned %d.%d.%d.%d", u.name, conn.RemoteAddr(), ip[0], ip[1], ip[2], ip[3])

	resp := append([]byte{0}, ip[:]...)
	if _, err := conn.Write(resp); err != nil {
		return
	}

	c := &client{conn: conn, ip: ip, user: u, meter: m, in: make(chan packet, clientQueue), out: make(chan packet, clientQueue)}
	s.mu.Lock()
	s.clients[ip] = c
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.clients, ip)
		s.mu.Unlock()
	}()

	done := make(chan struct{})
	defer close(done)
	go c.drain(c.out, c.writeFramedLocked, done)
	go c.drain(c.in, s.writeTun, done)
	go func() {
		ticker := time.NewTicker(heartbeatInterval)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				if err := c.writeFramedLocked(nil); err != nil {
					return
				}
			}
		}
	}()

	// conn -> tun. A read deadline, refreshed on every successful read,
	// detects a connection that's gone silently dead (no data, not even a
	// heartbeat, within readTimeout) so the goroutine/IP get cleaned up
	// instead of leaking forever.
	for {
		conn.SetReadDeadline(time.Now().Add(readTimeout))
		pkt, err := readFramed(r)
		if err != nil {
			if err != io.EOF {
				log.Printf("client %q read error: %v", u.name, err)
			}
			return
		}
		if len(pkt) == 0 {
			continue // heartbeat from client, nothing to forward
		}
		c.schedule(&m.up, c.in, pkt)
	}
}

func (s *server) writeTun(pkt []byte) error {
	_, err := s.tun.Write(pkt)
	if err != nil {
		log.Printf("tun write error: %v", err)
	}
	return err
}

// authenticate reads and checks the auth frame, and always ends the login
// attempt that handleConn began for source. admin reports whether the client
// asked for the admin API, not whether the user is allowed to use it.
func (s *server) authenticate(conn net.Conn, r *bufio.Reader, source string) (u user, admin, ok bool) {
	rejected := false
	defer func() { s.logins.end(source, rejected, time.Now()) }()

	if first, err := r.Peek(1); err == nil && first[0] == adminMarker {
		admin = true
		r.Discard(1)
	}
	username, password, err := readAuth(r)
	if err != nil {
		log.Printf("auth read error from %s: %v", conn.RemoteAddr(), err)
		return u, admin, false
	}
	u, ok = lookupUser(s.userDB, username)
	hash := u.hash
	if !ok {
		// Spend the same time on unknown users, so timing doesn't reveal usernames.
		hash = dummyHash
	}
	if bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) != nil || !ok {
		rejected = true
		log.Printf("auth failed for user %q from %s", username, conn.RemoteAddr())
		conn.Write([]byte{1})
		return u, admin, false
	}
	return u, admin, true
}

const (
	firstClientIP = 2
	lastClientIP  = 253
)

// allocateIP hands out addresses round-robin rather than lowest-free, so late
// packets for a user who just left don't reach whoever connects next.
func (s *server) allocateIP() ([4]byte, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for range lastClientIP - firstClientIP + 1 {
		n := s.nextIP
		s.nextIP++
		if s.nextIP > lastClientIP {
			s.nextIP = firstClientIP
		}
		if !s.usedIPs[n] {
			s.usedIPs[n] = true
			return [4]byte{s.subnet[0], s.subnet[1], s.subnet[2], n}, true
		}
	}
	return [4]byte{}, false
}

func (s *server) releaseIP(ip [4]byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.usedIPs[ip[3]] = false
}

func readAuth(r *bufio.Reader) (username, password string, err error) {
	ulen, err := r.ReadByte()
	if err != nil {
		return "", "", err
	}
	ubuf := make([]byte, ulen)
	if _, err := io.ReadFull(r, ubuf); err != nil {
		return "", "", err
	}
	plen, err := r.ReadByte()
	if err != nil {
		return "", "", err
	}
	pbuf := make([]byte, plen)
	if _, err := io.ReadFull(r, pbuf); err != nil {
		return "", "", err
	}
	return string(ubuf), string(pbuf), nil
}

func readFramed(r *bufio.Reader) ([]byte, error) {
	return readFramedMax(r, 65535)
}

func readFramedMax(r *bufio.Reader, max int) ([]byte, error) {
	var lenBuf [2]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint16(lenBuf[:])
	if int(n) > max {
		return nil, fmt.Errorf("frame of %d bytes is over the %d limit", n, max)
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	return buf, nil
}

func writeFramed(w io.Writer, pkt []byte) error {
	var lenBuf [2]byte
	binary.BigEndian.PutUint16(lenBuf[:], uint16(len(pkt)))
	if _, err := w.Write(lenBuf[:]); err != nil {
		return err
	}
	_, err := w.Write(pkt)
	return err
}
