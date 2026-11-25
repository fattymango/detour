package main

import (
	"crypto/rand"
	"encoding/base64"
	"flag"
	"fmt"
	"log"
)

const defaultDBPath = "/var/lib/detour/users.db"

// runUserCommand handles the one-shot user commands. The running server
// notices changes made here within syncInterval.
func runUserCommand(cmd string, args []string) {
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	db := fs.String("db", defaultDBPath, "detour-server's user database")
	fs.Parse(args)
	rest := fs.Args()

	userDB, err := openUserDB(*db)
	if err != nil {
		log.Fatalf("opening user database: %v", err)
	}
	defer userDB.Close()

	switch cmd {
	case "adduser":
		if len(rest) < 1 {
			log.Fatal("usage: detour-server adduser <username> [password]")
		}
		name := rest[0]
		if err := checkUsername(name); err != nil {
			log.Fatal(err)
		}
		password := generatePassword()
		if len(rest) >= 2 {
			password = rest[1]
		}
		if _, exists := lookupUser(userDB, name); exists {
			err = setPassword(userDB, name, password)
		} else {
			err = addUser(userDB, name, password)
		}
		if err != nil {
			log.Fatalf("saving user: %v", err)
		}
		fmt.Printf("user %q added/updated\nusername: %s\npassword: %s\n", name, name, password)

	case "deluser":
		if len(rest) < 1 {
			log.Fatal("usage: detour-server deluser <username>")
		}
		if err := deleteUser(userDB, rest[0]); err != nil {
			log.Fatalf("deleting user: %v", err)
		}
		fmt.Printf("user %q removed\n", rest[0])

	case "setadmin":
		if len(rest) != 2 || (rest[1] != "on" && rest[1] != "off") {
			log.Fatal("usage: detour-server setadmin <username> on|off")
		}
		if err := setAdmin(userDB, rest[0], rest[1] == "on"); err != nil {
			log.Fatalf("updating user: %v", err)
		}
		fmt.Printf("user %q admin: %s\n", rest[0], rest[1])

	case "listusers":
		users, err := listUsers(userDB)
		if err != nil {
			log.Fatalf("listing users: %v", err)
		}
		for _, u := range users {
			if u.admin {
				fmt.Println(u.name, "(admin)")
			} else {
				fmt.Println(u.name)
			}
		}
	}
}

func generatePassword() string {
	buf := make([]byte, 16)
	rand.Read(buf) // never fails: crypto/rand aborts the program instead
	return base64.RawURLEncoding.EncodeToString(buf)
}
