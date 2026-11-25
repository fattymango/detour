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
	dbPath     = flag.String("db", "/var/lib/detour/users.db", "detour-server's own user database (see adduser/deluser/listusers)")
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

type client struct {
	conn    net.Conn
	writeMu sync.Mutex
	ip      [4]byte
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
	tun     *water.Interface
	userDB  *sql.DB
	subnet  [3]byte
}

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "adduser", "deluser", "listusers":
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
		nextIP:  2,
		tun:     iface,
		userDB:  userDB,
		subnet:  subnetBytes,
	}

	go s.tunReadLoop()

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
		c.writeFramedLocked(buf[:n])
	}
}

func (s *server) handleConn(conn net.Conn) {
	defer conn.Close()
	r := bufio.NewReader(conn)

	username, password, err := readAuth(r)
	if err != nil {
		log.Printf("auth read error from %s: %v", conn.RemoteAddr(), err)
		return
	}

	hash, ok := lookupVpnPasswordHash(s.userDB, username)
	if !ok || bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) != nil {
		log.Printf("auth failed for user %q from %s", username, conn.RemoteAddr())
		conn.Write([]byte{1})
		return
	}

	ip, ok := s.allocateIP()
	if !ok {
		log.Printf("no free IPs for user %q", username)
		conn.Write([]byte{1})
		return
	}
	defer s.releaseIP(ip)

	log.Printf("user %q connected from %s, assigned %d.%d.%d.%d", username, conn.RemoteAddr(), ip[0], ip[1], ip[2], ip[3])

	resp := append([]byte{0}, ip[:]...)
	if _, err := conn.Write(resp); err != nil {
		return
	}

	c := &client{conn: conn, ip: ip}
	s.mu.Lock()
	s.clients[ip] = c
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.clients, ip)
		s.mu.Unlock()
	}()

	heartbeatDone := make(chan struct{})
	defer close(heartbeatDone)
	go func() {
		ticker := time.NewTicker(heartbeatInterval)
		defer ticker.Stop()
		for {
			select {
			case <-heartbeatDone:
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
				log.Printf("client %q read error: %v", username, err)
			}
			return
		}
		if len(pkt) == 0 {
			continue // heartbeat from client, nothing to forward
		}
		if _, err := s.tun.Write(pkt); err != nil {
			log.Printf("tun write error: %v", err)
			return
		}
	}
}

func (s *server) allocateIP() ([4]byte, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.nextIP >= 254 {
		return [4]byte{}, false
	}
	ip := [4]byte{s.subnet[0], s.subnet[1], s.subnet[2], s.nextIP}
	s.nextIP++
	return ip, true
}

func (s *server) releaseIP(ip [4]byte) {
	// Simple allocator: no reuse within process lifetime. Fine for small
	// personal deployments; restart the service to reset the pool.
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
	var lenBuf [2]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return nil, err
	}
	n := binary.BigEndian.Uint16(lenBuf[:])
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
