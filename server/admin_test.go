package main

import (
	"bufio"
	"database/sql"
	"encoding/json"
	"io"
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestAdmin(t *testing.T) {
	db, err := openUserDB(filepath.Join(t.TempDir(), "users.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	for _, name := range []string{"boss", "plain"} {
		if err := addUser(db, name, "pw"); err != nil {
			t.Fatal(err)
		}
	}
	if err := setAdmin(db, "boss", true); err != nil {
		t.Fatal(err)
	}
	s := &server{clients: map[[4]byte]*client{}, nextIP: firstClientIP, userDB: db}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go s.handleConn(c)
		}
	}()

	open := func(marker, name, pw string) (net.Conn, byte) {
		t.Helper()
		c, err := net.Dial("tcp", ln.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		c.SetDeadline(time.Now().Add(5 * time.Second))
		io.WriteString(c, marker+string(rune(len(name)))+name+string(rune(len(pw)))+pw)
		b := make([]byte, 1)
		if _, err := io.ReadFull(c, b); err != nil {
			t.Fatalf("login %s: %v", name, err)
		}
		return c, b[0]
	}
	call := func(name, pw, op, target string) adminResponse {
		t.Helper()
		c, status := open("\x00", name, pw)
		if status != 0 {
			return adminResponse{Error: "login rejected"}
		}
		body, _ := json.Marshal(adminRequest{Op: op, Username: target})
		writeFramed(c, body)
		var resp adminResponse
		if err := json.NewDecoder(c).Decode(&resp); err != nil {
			t.Fatal(err)
		}
		return resp
	}
	// vpn logs in and returns once the server has registered the client.
	vpn := func(name, pw string) (net.Conn, byte) {
		t.Helper()
		c, status := open("", name, pw)
		for end := time.Now().Add(2 * time.Second); status == 0 && time.Now().Before(end); time.Sleep(5 * time.Millisecond) {
			s.mu.Lock()
			n := 0
			for _, cl := range s.clients {
				if cl.user.name == name {
					n++
				}
			}
			s.mu.Unlock()
			if n > 0 {
				break
			}
		}
		return c, status
	}
	closed := func(c net.Conn) bool {
		c.SetDeadline(time.Now().Add(2 * time.Second))
		_, err := io.Copy(io.Discard, c)
		return err == nil
	}

	for _, op := range []string{"list", "add", "reset", "remove", "setlimits", "resetusage"} {
		if r := call("plain", "pw", op, "boss"); !strings.Contains(r.Error, "not an admin") || r.Users != nil || r.Password != "" {
			t.Errorf("non-admin %s: %+v", op, r)
		}
	}
	if r := call("boss", "wrong", "list", ""); r.Error != "login rejected" {
		t.Errorf("wrong password: %+v", r)
	}

	r := call("boss", "pw", "add", "ali")
	if r.Error != "" || r.Password == "" {
		t.Fatalf("add: %+v", r)
	}
	if r := call("boss", "pw", "add", "ali"); r.Error == "" || r.Password != "" {
		t.Errorf("duplicate add: %+v", r)
	}
	for _, bad := range []string{"", "a b", "../x", "a\nb", strings.Repeat("a", 33)} {
		if r := call("boss", "pw", "add", bad); r.Error == "" {
			t.Errorf("accepted username %q", bad)
		}
	}

	ali, status := vpn("ali", r.Password)
	plain, _ := vpn("plain", "pw")
	if status != 0 {
		t.Fatal("new user can't connect")
	}
	for _, u := range call("boss", "pw", "list", "").Users {
		want := map[string]adminUser{"ali": {Username: "ali", Connected: 1}, "boss": {Username: "boss", Admin: true}, "plain": {Username: "plain", Connected: 1}}[u.Username]
		if u != want {
			t.Errorf("list: got %+v, want %+v", u, want)
		}
	}

	reset := call("boss", "pw", "reset", "ali")
	if reset.Error != "" || reset.Password == r.Password || !closed(ali) {
		t.Errorf("reset must change the password and disconnect: %+v", reset)
	}
	if _, status := open("", "ali", r.Password); status != 1 {
		t.Error("old password still works after reset")
	}
	ali, status = vpn("ali", reset.Password)
	if status != 0 {
		t.Fatal("new password rejected")
	}
	if r := call("boss", "pw", "remove", "ali"); r.Error != "" || !closed(ali) {
		t.Errorf("remove must disconnect: %+v", r)
	}
	if _, status := open("", "ali", reset.Password); status != 1 {
		t.Error("removed user can still log in")
	}
	if r := call("boss", "pw", "remove", "ali"); r.Error == "" {
		t.Error("removing a missing user succeeded")
	}
	if r := call("boss", "pw", "remove", "boss"); r.Error == "" {
		t.Error("admin removed themselves")
	}

	s.mu.Lock()
	var kept bool
	for _, c := range s.clients {
		kept = kept || c.user.name == "plain"
	}
	s.mu.Unlock()
	if !kept {
		t.Error("unrelated user was disconnected")
	}
	if err := deleteUser(db, "plain"); err != nil {
		t.Fatal(err)
	}
	s.syncUsers()
	if !closed(plain) {
		t.Error("user removed outside the API stayed connected")
	}
	if c, status := open("\x00", "boss", "pw"); status == 0 {
		c.Write([]byte{0xff, 0xff})
		if n, _ := bufio.NewReader(c).Read(make([]byte, 1)); n != 0 {
			t.Error("oversized request got an answer")
		}
	}
}

func TestMigrateOldDB(t *testing.T) {
	path := filepath.Join(t.TempDir(), "old.db")
	old, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := old.Exec("CREATE TABLE users (username TEXT PRIMARY KEY, password_hash TEXT NOT NULL); INSERT INTO users VALUES ('phone', 'h')"); err != nil {
		t.Fatal(err)
	}
	old.Close()
	for range 2 {
		db, err := openUserDB(path)
		if err != nil {
			t.Fatal(err)
		}
		if u, ok := lookupUser(db, "phone"); !ok || u.hash != "h" || u.admin {
			t.Fatalf("got %+v %v", u, ok)
		}
		db.Close()
	}
}
