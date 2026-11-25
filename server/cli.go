package main

import (
	"crypto/rand"
	"encoding/base64"
	"flag"
	"fmt"
	"log"
	"os"

	"golang.org/x/crypto/bcrypt"
)

const defaultDBPath = "/var/lib/detour/users.db"

// runUserCommand handles `detour-server adduser|deluser|listusers`, the
// standalone replacement for what used to be auth-server's job. Each
// subcommand opens the user db itself (read-write) and closes it when done -
// these are one-shot CLI invocations, not the long-running server process.
func runUserCommand(cmd string, args []string) {
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	db := fs.String("db", defaultDBPath, "detour-server's user database")
	fs.Parse(args)

	userDB, err := openUserDB(*db)
	if err != nil {
		log.Fatalf("opening user database: %v", err)
	}
	defer userDB.Close()

	switch cmd {
	case "adduser":
		rest := fs.Args()
		if len(rest) < 1 {
			log.Fatal("usage: detour-server adduser <username> [password]")
		}
		username := rest[0]
		password := ""
		if len(rest) >= 2 {
			password = rest[1]
		} else {
			password = generatePassword()
		}
		hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
		if err != nil {
			log.Fatalf("hashing password: %v", err)
		}
		if _, err := userDB.Exec(
			"INSERT INTO users (username, password_hash) VALUES (?, ?) ON CONFLICT(username) DO UPDATE SET password_hash = excluded.password_hash",
			username, string(hash),
		); err != nil {
			log.Fatalf("saving user: %v", err)
		}
		fmt.Printf("user %q added/updated\nusername: %s\npassword: %s\n", username, username, password)

	case "deluser":
		rest := fs.Args()
		if len(rest) < 1 {
			log.Fatal("usage: detour-server deluser <username>")
		}
		if _, err := userDB.Exec("DELETE FROM users WHERE username = ?", rest[0]); err != nil {
			log.Fatalf("deleting user: %v", err)
		}
		fmt.Printf("user %q removed\n", rest[0])

	case "listusers":
		rows, err := userDB.Query("SELECT username FROM users ORDER BY username")
		if err != nil {
			log.Fatalf("listing users: %v", err)
		}
		defer rows.Close()
		for rows.Next() {
			var username string
			if err := rows.Scan(&username); err != nil {
				log.Fatalf("reading row: %v", err)
			}
			fmt.Println(username)
		}
	}
}

func generatePassword() string {
	buf := make([]byte, 16)
	if _, err := rand.Read(buf); err != nil {
		fmt.Fprintln(os.Stderr, "warning: crypto/rand failed, this should never happen:", err)
		os.Exit(1)
	}
	return base64.RawURLEncoding.EncodeToString(buf)
}
