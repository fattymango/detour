package main

import (
	"database/sql"
	"errors"
	"fmt"

	"golang.org/x/crypto/bcrypt"
	_ "modernc.org/sqlite"
)

var errNoSuchUser = errors.New("no such user")

type user struct {
	name  string
	hash  string
	admin bool

	// 0 means unlimited.
	speedKbps  int64
	quotaBytes int64
	usedBytes  int64
}

const userColumns = "username, password_hash, is_admin, speed_kbps, quota_bytes, used_bytes"

func scanUser(row interface{ Scan(...any) error }) (u user, err error) {
	err = row.Scan(&u.name, &u.hash, &u.admin, &u.speedKbps, &u.quotaBytes, &u.usedBytes)
	return u, err
}

// openUserDB opens (creating if needed) the user database. The CLI and the
// running server may use it at the same time.
func openUserDB(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", "file:"+path+"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)")
	if err != nil {
		return nil, err
	}
	if err := migrate(db); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}

func migrate(db *sql.DB) error {
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS users (
		username TEXT PRIMARY KEY,
		password_hash TEXT NOT NULL
	)`); err != nil {
		return err
	}
	for _, column := range []string{"is_admin", "speed_kbps", "quota_bytes", "used_bytes"} {
		var exists bool
		if err := db.QueryRow("SELECT COUNT(*) FROM pragma_table_info('users') WHERE name = ?", column).Scan(&exists); err != nil {
			return err
		}
		if exists {
			continue
		}
		if _, err := db.Exec("ALTER TABLE users ADD COLUMN " + column + " INTEGER NOT NULL DEFAULT 0"); err != nil {
			return err
		}
	}
	return nil
}

func lookupUser(db *sql.DB, name string) (user, bool) {
	u, err := scanUser(db.QueryRow("SELECT "+userColumns+" FROM users WHERE username = ?", name))
	return u, err == nil
}

func listUsers(db *sql.DB) ([]user, error) {
	rows, err := db.Query("SELECT " + userColumns + " FROM users ORDER BY username")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var users []user
	for rows.Next() {
		u, err := scanUser(rows)
		if err != nil {
			return nil, err
		}
		users = append(users, u)
	}
	return users, rows.Err()
}

// addUser fails if the user already exists.
func addUser(db *sql.DB, name, password string) error {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	res, err := db.Exec("INSERT INTO users (username, password_hash) VALUES (?, ?) ON CONFLICT(username) DO NOTHING", name, string(hash))
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return fmt.Errorf("user %q already exists", name)
	}
	return nil
}

func setPassword(db *sql.DB, name, password string) error {
	hash, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	if err != nil {
		return err
	}
	return mustAffect(db.Exec("UPDATE users SET password_hash = ? WHERE username = ?", string(hash), name))
}

func setAdmin(db *sql.DB, name string, admin bool) error {
	return mustAffect(db.Exec("UPDATE users SET is_admin = ? WHERE username = ?", admin, name))
}

func setLimits(db *sql.DB, name string, speedKbps, quotaBytes int64) error {
	return mustAffect(db.Exec("UPDATE users SET speed_kbps = ?, quota_bytes = ? WHERE username = ?", speedKbps, quotaBytes, name))
}

func resetUsage(db *sql.DB, name string) error {
	return mustAffect(db.Exec("UPDATE users SET used_bytes = 0 WHERE username = ?", name))
}

func deleteUser(db *sql.DB, name string) error {
	return mustAffect(db.Exec("DELETE FROM users WHERE username = ?", name))
}

func mustAffect(res sql.Result, err error) error {
	if err != nil {
		return err
	}
	if n, _ := res.RowsAffected(); n == 0 {
		return errNoSuchUser
	}
	return nil
}
