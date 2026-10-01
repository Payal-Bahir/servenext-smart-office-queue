package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"
)

const pbkdf2Iterations = 100_000

type Staff struct {
	ID           int    `json:"id"`
	Username     string `json:"username"`
	FullName     string `json:"full_name"`
	Role         string `json:"role"` 
	DepartmentID *int   `json:"department_id"`
}


func (s *Staff) require(dept int) error {
	if s.Role == "admin" || (s.DepartmentID != nil && *s.DepartmentID == dept) {
		return nil
	}
	return httpErr(403, "you are not allowed to manage this department")
}



func pbkdf2(password, salt []byte, iter int) []byte {
	mac := hmac.New(sha256.New, password)
	mac.Write(salt)
	mac.Write([]byte{0, 0, 0, 1})
	u := mac.Sum(nil)
	out := make([]byte, len(u))
	copy(out, u)
	for i := 1; i < iter; i++ {
		mac.Reset()
		mac.Write(u)
		u = mac.Sum(nil)
		for j := range out {
			out[j] ^= u[j]
		}
	}
	return out
}

func hashPassword(pw string) string {
	salt := make([]byte, 16)
	_, _ = rand.Read(salt)
	return hex.EncodeToString(salt) + "$" + hex.EncodeToString(pbkdf2([]byte(pw), salt, pbkdf2Iterations))
}

func checkPassword(pw, stored string) bool {
	parts := strings.SplitN(stored, "$", 2)
	if len(parts) != 2 {
		return false
	}
	salt, err1 := hex.DecodeString(parts[0])
	want, err2 := hex.DecodeString(parts[1])
	if err1 != nil || err2 != nil {
		return false
	}
	return subtle.ConstantTimeCompare(pbkdf2([]byte(pw), salt, pbkdf2Iterations), want) == 1
}



func (a *App) sign(staffID int) string {
	p, _ := json.Marshal(map[string]int64{"sid": int64(staffID), "exp": time.Now().Add(12 * time.Hour).Unix()})
	body := base64.RawURLEncoding.EncodeToString(p)
	m := hmac.New(sha256.New, a.secret)
	m.Write([]byte(body))
	return body + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil))
}

func (a *App) verify(tok string) (int, bool) {
	parts := strings.Split(tok, ".")
	if len(parts) != 2 {
		return 0, false
	}
	m := hmac.New(sha256.New, a.secret)
	m.Write([]byte(parts[0]))
	got, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || !hmac.Equal(got, m.Sum(nil)) {
		return 0, false
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return 0, false
	}
	var p struct {
		Sid int64 `json:"sid"`
		Exp int64 `json:"exp"`
	}
	if json.Unmarshal(raw, &p) != nil || time.Now().Unix() > p.Exp {
		return 0, false
	}
	return int(p.Sid), true
}

func (a *App) loadStaff(ctx context.Context, id int) (*Staff, error) {
	var s Staff
	var dept sql.NullInt64
	err := a.db.QueryRowContext(ctx,
		`SELECT id, username, full_name, role, department_id FROM staff WHERE id=$1`, id,
	).Scan(&s.ID, &s.Username, &s.FullName, &s.Role, &dept)
	if err != nil {
		return nil, err
	}
	if dept.Valid {
		d := int(dept.Int64)
		s.DepartmentID = &d
	}
	return &s, nil
}


func (a *App) authed(fn func(http.ResponseWriter, *http.Request, *Staff) error) http.HandlerFunc {
	return wrap(func(w http.ResponseWriter, r *http.Request) error {
		h := r.Header.Get("Authorization")
		if !strings.HasPrefix(h, "Bearer ") {
			return httpErr(401, "login required")
		}
		sid, ok := a.verify(strings.TrimPrefix(h, "Bearer "))
		if !ok {
			return httpErr(401, "session expired, please log in again")
		}
		s, err := a.loadStaff(r.Context(), sid)
		if errors.Is(err, sql.ErrNoRows) {
			return httpErr(401, "account not found, please log in again")
		}
		if err != nil {
			return err
		}
		return fn(w, r, s)
	})
}

func (a *App) login(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	if err := readJSON(r, &in); err != nil {
		return err
	}
	var id int
	var hash string
	err := a.db.QueryRowContext(r.Context(),
		`SELECT id, password_hash FROM staff WHERE username=$1`, strings.TrimSpace(in.Username),
	).Scan(&id, &hash)
	if errors.Is(err, sql.ErrNoRows) || (err == nil && !checkPassword(in.Password, hash)) {
		return httpErr(401, "invalid username or password")
	}
	if err != nil {
		return err
	}
	s, err := a.loadStaff(r.Context(), id)
	if err != nil {
		return err
	}
	writeJSON(w, 200, map[string]any{"token": a.sign(id), "staff": s})
	return nil
}

func (a *App) me(w http.ResponseWriter, r *http.Request, s *Staff) error {
	writeJSON(w, 200, s)
	return nil
}


func (a *App) seedStaff() error {
	seed := []struct{ user, pass, name, role, dept string }{
		{"admin", "admin123", "System Admin", "admin", ""},
		{"it.staff", "staff123", "IT Desk Officer", "staff", "IT"},
		{"hr.staff", "staff123", "HR Desk Officer", "staff", "HR"},
		{"acc.staff", "staff123", "Accounts Officer", "staff", "ACC"},
		{"adm.staff", "staff123", "Admin Desk Officer", "staff", "ADM"},
	}
	for _, s := range seed {
		var exists bool
		if err := a.db.QueryRow(`SELECT EXISTS(SELECT 1 FROM staff WHERE username=$1)`, s.user).Scan(&exists); err != nil {
			return err
		}
		if exists {
			continue
		}
		var dept any
		if s.dept != "" {
			var id int
			if err := a.db.QueryRow(`SELECT id FROM departments WHERE code=$1`, s.dept).Scan(&id); err != nil {
				return err
			}
			dept = id
		}
		if _, err := a.db.Exec(
			`INSERT INTO staff (username, password_hash, full_name, role, department_id) VALUES ($1,$2,$3,$4,$5)`,
			s.user, hashPassword(s.pass), s.name, s.role, dept); err != nil {
			return err
		}
	}
	return nil
}
