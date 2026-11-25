package main

import (
	"encoding/json"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// api sends one request as name/pw; denied reports a rejected login.
func (e *env) api(name, pw string, req adminRequest) (resp adminResponse, denied bool) {
	c, status := e.login("\x00", name, pw)
	defer c.Close()
	if status != 0 {
		return resp, true
	}
	body, _ := json.Marshal(req)
	writeFramed(c, body)
	if err := json.NewDecoder(c).Decode(&resp); err != nil {
		e.t.Error(err)
	}
	return resp, false
}

func (e *env) login(marker, name, pw string) (net.Conn, byte) {
	c, err := net.Dial("tcp", e.ln.Addr().String())
	if err != nil {
		e.t.Fatal(err)
	}
	c.SetDeadline(time.Now().Add(10 * time.Second))
	io.WriteString(c, marker+string(rune(len(name)))+name+string(rune(len(pw)))+pw)
	b := []byte{255}
	io.ReadFull(c, b)
	return c, b[0]
}

func TestInviteWorksOnce(t *testing.T) {
	e := newEnv(t)
	invite := e.admin(adminRequest{Op: "add", Username: "ali"}).Password
	if u := e.info("ali"); !u.Invite {
		t.Errorf("new user isn't an unclaimed invite: %+v", u)
	}
	if c, status := e.login("", "ali", invite); status != 4 {
		t.Errorf("VPN login with an invite: status %d", status)
	} else {
		c.Close()
	}
	for _, bad := range []string{"", "short", strings.Repeat("a", 31), strings.Repeat("a", 65), strings.Repeat("a", 31) + "!"} {
		if r, _ := e.api("ali", invite, adminRequest{Op: "claim", Password: bad}); r.Error == "" || r.Claimed {
			t.Errorf("claimed with password %q", bad)
		}
	}

	var wg sync.WaitGroup
	won := make(chan string, 5)
	for i := range 5 {
		wg.Go(func() {
			pw := strings.Repeat(string(rune('a'+i)), 32)
			if r, denied := e.api("ali", invite, adminRequest{Op: "claim", Password: pw}); !denied && r.Claimed {
				won <- pw
			}
		})
	}
	wg.Wait()
	if len(won) != 1 {
		t.Fatalf("%d devices claimed one invite", len(won))
	}
	pw := <-won
	if _, denied := e.api("ali", invite, adminRequest{Op: "claim", Password: strings.Repeat("z", 32)}); !denied {
		t.Error("used invite still logs in")
	}
	if r, denied := e.api("ali", pw, adminRequest{Op: "claim", Password: strings.Repeat("z", 32)}); denied || r.Error != "" || r.Claimed {
		t.Errorf("repeat claim by the owner: %+v denied=%v", r, denied)
	}
	if c, status := e.login("", "ali", pw); status != 0 {
		t.Errorf("claimed login: status %d", status)
	} else {
		c.Close()
	}
	if u := e.info("ali"); u.Invite {
		t.Error("still shown as unclaimed")
	}

	again := e.admin(adminRequest{Op: "reset", Username: "ali"}).Password
	if c, status := e.login("", "ali", pw); status != 1 {
		t.Errorf("old device after a new link: status %d", status)
	} else {
		c.Close()
	}
	if r, _ := e.api("ali", again, adminRequest{Op: "claim", Password: pw}); !r.Claimed {
		t.Errorf("claiming the new link: %+v", r)
	}
}

func TestUnclaimedAdminCanOnlyClaim(t *testing.T) {
	e := newEnv(t)
	if err := addUser(e.s.userDB, "root", "invitepw"); err != nil {
		t.Fatal(err)
	}
	if err := setAdmin(e.s.userDB, "root", true); err != nil {
		t.Fatal(err)
	}
	if r, _ := e.api("root", "invitepw", adminRequest{Op: "list"}); r.Error == "" || r.Users != nil {
		t.Errorf("unclaimed admin listed users: %+v", r)
	}
	pw := strings.Repeat("k", 32)
	if r, _ := e.api("root", "invitepw", adminRequest{Op: "claim", Password: pw}); !r.Claimed {
		t.Fatalf("claim: %+v", r)
	}
	if r, _ := e.api("root", pw, adminRequest{Op: "list"}); r.Error != "" || len(r.Users) != 2 {
		t.Errorf("claimed admin: %+v", r)
	}
}
