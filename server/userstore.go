package main

import (
	"database/sql"

	_ "modernc.org/sqlite"
)

// openUserDB opens (creating if needed) detour-server's own SQLite user
// database. Unlike swissknife's tunnel-server, which read another service's
// shared database, this is a self-contained store: detour-server owns it
// fully, read and write, via the adduser/deluser/listusers subcommands.
func openUserDB(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=journal_mode(WAL)")
	if err != nil {
		return nil, err
	}
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS users (
		username TEXT PRIMARY KEY,
		password_hash TEXT NOT NULL
	)`); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

// lookupVpnPasswordHash looks up the given username's bcrypt hash. Queried
// fresh on every connection attempt - no in-memory cache to go stale.
func lookupVpnPasswordHash(db *sql.DB, username string) (string, bool) {
	var hash string
	err := db.QueryRow(
		"SELECT password_hash FROM users WHERE username = ?",
		username,
	).Scan(&hash)
	if err != nil {
		return "", false
	}
	return hash, true
}
